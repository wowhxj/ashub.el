;;; ashub-details.el --- Compact metadata and readable chat details -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Package-Requires: ((emacs "29.1"))
;; Version: 0.1.0
;; Keywords: tools, processes

;;; Commentary:
;; A read-only presentation of saved dialogue.  Layout is derived from cached
;; text, never by calling an agent or a model.  Copy buttons retain original
;; message text rather than the whitespace added for chat presentation.

;;; Code:
(require 'ashub-core)
(require 'ashub-summary)
(require 'button)

(declare-function ashub--display-full-buffer "ashub" (buffer))
(declare-function ashub--source-label "ashub" (source))
(declare-function ashub--summary-status "ashub" (session))

(defcustom ashub-details-message-width 100
  "Maximum chat bubble width, in display columns."
  :type 'integer :group 'ashub)
(defcustom ashub-details-message-width-ratio 0.76
  "Maximum fraction of the window occupied by one message."
  :type 'number :group 'ashub)

(defface ashub-details-user-face
  '((((class color) (background light)) :background "#e7f0ff" :extend nil)
    (((class color) (background dark)) :background "#29384b" :extend nil)
    (t :inherit shadow))
  "Background of right-aligned user messages." :group 'ashub)
(defface ashub-details-assistant-face
  '((((class color) (background light)) :background "#f4f0df" :extend nil)
    (((class color) (background dark)) :background "#403b2a" :extend nil)
    (t :inherit default))
  "Background of left-aligned agent messages." :group 'ashub)

(defvar-local ashub-details--session nil)
(defvar-local ashub-details--conversation nil)
(defvar-local ashub-details--turns nil)
(defvar-local ashub-details--stale nil)
(defvar-local ashub-details--width nil)
(defvar-local ashub-details--rendering nil)
(defvar-local ashub-details--metadata-expanded nil)
(defvar-local ashub-details--metadata-overlay nil)
(defvar-local ashub-details--metadata-button nil)

(defun ashub-details--parse (text)
  "Parse exported TEXT into role/text/label turns, respecting fenced code."
  (let (turns role label lines fence-char fence-length previous)
    (cl-labels ((finish ()
                  (when (or role lines)
                    (push (list :role (or role 'notice) :label label
                                :text (string-trim (mapconcat #'identity (nreverse lines) "\n")
                                                   "\n+" "\n+")) turns))
                  (setq lines nil)))
      (dolist (line (split-string text "\n"))
        (let* ((fence (string-match "^[ \t]*\\(`\\{3,\\}\\|~\\{3,\\}\\)" line))
               (marker (and fence (match-string 1 line)))
               (heading
                (and (not fence-char)
                     (or (string-match "^## \\(User\\|Assistant\\)\\(?: · .*\\)?[ \t]*$" line)
                         (and (or (null previous) (string-empty-p (string-trim previous)))
                              (string-match "^\\(User\\|Assistant\\|Pi\\|Summary\\|Branch summary\\):\\(?: \\|$\\)" line)))))
               (speaker (and heading (match-string 1 line)))
               (body (and heading (substring line (match-end 0)))))
          (if heading
              (progn
                (finish)
                (setq role (if (equal speaker "User") 'user 'assistant)
                      label (if (member speaker '("Summary" "Branch summary")) speaker nil))
                (unless (string-empty-p body) (push body lines)))
            (push line lines))
          (when marker
            (cond ((null fence-char) (setq fence-char (aref marker 0) fence-length (length marker)))
                  ((and (= fence-char (aref marker 0)) (>= (length marker) fence-length)
                        (string-match-p (concat "^[ \t]*" (regexp-quote marker) "[ \t]*$") line))
                   (setq fence-char nil fence-length nil))))
          (setq previous line)))
      (finish))
    (seq-remove (lambda (turn) (and (eq (plist-get turn :role) 'notice)
                                    (string-empty-p (string-trim (plist-get turn :text)))))
                (nreverse turns))))

(defun ashub-details--wrap-line (line width)
  "Wrap one display LINE to WIDTH without dropping characters.
Tabs are expanded only for presentation; original message text is retained."
  (let* ((text (replace-regexp-in-string "\t" (make-string tab-width ?\s) line t t))
         (size (length text)) (start 0) (position 0) (columns 0) last-space rows)
    ;; Walk characters instead of repeatedly measuring/copying the remaining
    ;; suffix: a single very long paragraph should not make opening O(n²).
    (while (< position size)
      (let ((advance (max 0 (or (char-width (aref text position)) 1))))
        (if (and (> (+ columns advance) width) (> position start))
            (let ((cut (if (and last-space (> (- last-space start) (/ (- position start) 2)))
                           last-space position)))
              (push (substring text start cut) rows)
              (setq start cut position cut columns 0 last-space nil))
          (setq columns (+ columns advance) position (1+ position))
          (when (= (aref text (1- position)) ?\s) (setq last-space position)))))
    (nreverse (cons (substring text start) rows))))

(defun ashub-details--wrap (text width)
  "Return display rows for TEXT, preserving paragraph breaks and indentation."
  (apply #'append (mapcar (lambda (line) (ashub-details--wrap-line line width))
                          (split-string text "\n"))))

(defun ashub-details--copy-message (button)
  "Copy BUTTON's original message, without display padding or reflow."
  (kill-new (button-get button 'ashub-original))
  (message "已复制原始消息"))

(defun ashub-details-copy-conversation ()
  "Copy the original exported conversation without display-only wrapping."
  (interactive)
  (kill-new ashub-details--conversation)
  (message "已复制原始对话"))

(defun ashub-details--insert-message (turn index width)
  "Insert TURN number INDEX as a colored chat bubble within WIDTH."
  (let* ((user (eq (plist-get turn :role) 'user))
         (text (plist-get turn :text))
         (max-width (max 8 (min (max 8 ashub-details-message-width)
                                (floor (* (max 12 (- width 4))
                                          (max 0.3 (min 1.0 ashub-details-message-width-ratio)))))))
         (rows (ashub-details--wrap text (- max-width 4)))
         (label (if user "用户" (if (eq (plist-get turn :role) 'notice) "提示"
                                  (upcase (symbol-name (ashub-session-agent ashub-details--session))))))
         (label (if (plist-get turn :label) (concat label " · " (plist-get turn :label)) label))
         (bubble-width (min max-width (max 18 (+ 4 (apply #'max 0 (mapcar #'string-width rows))))))
         (indent (if user (max 1 (- width bubble-width 2)) 2))
         (face (list :inherit (if user 'ashub-details-user-face 'ashub-details-assistant-face)
                     :extend nil))
         (start (point)))
    (insert (make-string indent ?\s))
    (let* ((heading-start (point))
           (heading (concat "  " (truncate-string-to-width label (max 1 (- bubble-width 12))) "  ")))
      (insert (propertize heading 'face (append '(:weight bold) face)))
      (insert-text-button "复制" 'follow-link t 'action #'ashub-details--copy-message
                          'ashub-original text 'help-echo "复制原文，不含聊天排版的空格与换行"
                          'face (append '(:underline t) face))
      (insert (propertize (make-string (max 0 (- bubble-width (string-width heading) 4)) ?\s)
                          'face face))
      (put-text-property heading-start (point) 'ashub-details-side (if user 'right 'left)))
    (insert "\n")
    (dolist (row rows)
      (insert (make-string indent ?\s))
      (let ((body-start (point)))
        (insert (propertize (concat "  " row (make-string (max 0 (- bubble-width 2 (string-width row))) ?\s))
                            'face face))
        (put-text-property body-start (point) 'ashub-details-side (if user 'right 'left)))
      (insert "\n"))
    (add-text-properties start (point) (list 'ashub-turn-index index 'ashub-role (plist-get turn :role)))
    (insert "\n")))

(defun ashub-details--metadata-text ()
  "Return complete metadata for the expandable inspector."
  (let* ((session ashub-details--session) (entry (ashub-summary-entry session)))
    (concat
     (format "Agent: %s\nSession ID: %s\nSource: %s\nStorage path: %s\nProject: %s\nStorage root: %s\nProfile label: %S\nOrigin: %S\n"
             (ashub-session-agent session) (ashub-session-id session)
             (ashub--source-label (ashub-session-source session)) (or (ashub-session-path session) "unknown")
             (or (ashub-session-cwd session) "unknown") (plist-get (ashub-session-source session) :root)
             (plist-get (ashub-session-source session) :profile) (ashub-session-origin session))
     (format "Interaction time: %S\nTime source: %S\nInternal: %S; Empty: %S; Archived: %S\nData: %s\n"
             (ashub-session-last-active session) (ashub-session-time-source session)
             (ashub-session-internal session) (ashub-session-empty session) (ashub-session-archived session)
             (if ashub-details--stale "stale; refresh failed" "see source status"))
     (when (ashub-session-title session) (format "Title (not a raw first message): %s\n" (ashub-session-title session)))
     (format "Summary model: %s; generated: %s\n" (or (plist-get entry :model) "unknown")
             (if (plist-get entry :generated-at)
                 (format-time-string "%Y-%m-%d %H:%M:%S" (seconds-to-time (plist-get entry :generated-at))) "unknown"))
     (when (plist-get entry :error) (format "Summary error: %s\n" (plist-get entry :error)))
     (format "\nFirst user message:\n%s\n\nLast user message:\n%s\n"
             (or (ashub-session-first-message session) "[unknown]")
             (or (plist-get (plist-get (ashub-session-metadata session) :reference) :last) "[unknown]"))
     (when (and (not (ashub-session-first-message session)) (plist-get (ashub-session-metadata session) :prompt-preview))
       (format "\nMessage preview (turnOutline; may be truncated):\n%s\n"
               (plist-get (ashub-session-metadata session) :prompt-preview)))
     (format "\nDisplayed date source: %S\n" (ashub-session-display-time-source session))
     (mapconcat (lambda (key)
                  (when-let* ((seconds (plist-get (ashub-session-metadata session) key)))
                    (format "%s: %s" key (format-time-string "%Y-%m-%d %H:%M:%S" (seconds-to-time seconds)))))
                '(:updated-at :created-at) "\n") "\n\n")))

(defun ashub-details--set-metadata-visibility ()
  "Apply the current inspector visibility and update its button."
  (when (overlayp ashub-details--metadata-overlay)
    (overlay-put ashub-details--metadata-overlay 'invisible
                 (unless ashub-details--metadata-expanded 'ashub-details-metadata)))
  (when ashub-details--metadata-button
    (with-silent-modifications
      (button-put ashub-details--metadata-button 'display
                  (if ashub-details--metadata-expanded "▾ 详细信息（m 收起）" "▸ 详细信息（m 展开）")))))

(defun ashub-details-toggle-metadata (&optional _button)
  "Toggle full metadata without re-reading history or calling a model."
  (interactive)
  (setq ashub-details--metadata-expanded (not ashub-details--metadata-expanded))
  (ashub-details--set-metadata-visibility))

(defun ashub-details--isearch-open (overlay)
  "Reveal metadata OVERLAY when searching for a hidden field."
  (with-current-buffer (overlay-buffer overlay)
    (setq ashub-details--metadata-expanded t)
    (ashub-details--set-metadata-visibility)))

(defun ashub-details--render (&optional width)
  "Render cached data at WIDTH without re-reading transcripts or calling models."
  (unless ashub-details--rendering
    (let* ((ashub-details--rendering t) (inhibit-read-only t)
           (width (max 24 (or width (window-body-width (get-buffer-window (current-buffer))) (frame-width))))
           (index (get-text-property (point) 'ashub-turn-index))
           (session ashub-details--session) (entry (ashub-summary-entry session))
           (time (ashub-session-display-time session))
           (id (ashub-session-id session))
           (identity (format "%s · %s" (upcase (symbol-name (ashub-session-agent session)))
                             (substring id 0 (min 8 (length id)))))
           (project (ashub-session-project session)))
      (remove-overlays)
      (erase-buffer)
      (setq ashub-details--width width)
      (insert (propertize identity 'face 'bold 'help-echo id)
              "  ·  " (propertize (truncate-string-to-width project (max 1 (- width (string-width identity) 5)) nil nil "…")
                                  'face 'shadow 'help-echo project) "\n")
      (insert (propertize
               (format "%s  ·  摘要：%s  ·  %d 条消息%s%s%s\n"
                       (if time
                           (concat (format-time-string "%Y-%m-%d %H:%M" (seconds-to-time time))
                                   (if (memq (ashub-session-display-time-source session) '(updated created)) "*" ""))
                         "时间未知")
                       (ashub--summary-status session)
                       (seq-count (lambda (turn) (memq (plist-get turn :role) '(user assistant))) ashub-details--turns)
                       (if ashub-details--stale "  [来源旧]" "")
                       (if (ashub-session-cwd-missing-p session) "  [目录缺失]" "")
                       (if (eq (ashub-session-archived session) t) "  [归档]" ""))
               'face 'shadow 'help-echo "时间后的 * 表示来源更新时间/创建时间，而不是已验证的交互时间"))
      (when-let* ((summary (plist-get entry :summary)))
        (dolist (line (ashub-details--wrap (concat "摘要  " summary) (max 12 (- width 2))))
          (insert line "\n")))
      (setq ashub-details--metadata-button
            (insert-text-button "▸ 详细信息（m 展开）" 'follow-link t
                                'action #'ashub-details-toggle-metadata))
      (insert "\n")
      (let ((start (point)))
        (insert (ashub-details--metadata-text))
        (setq ashub-details--metadata-overlay (make-overlay start (point)))
        (overlay-put ashub-details--metadata-overlay 'ashub-details-metadata t)
        (overlay-put ashub-details--metadata-overlay 'isearch-open-invisible #'ashub-details--isearch-open)
        (ashub-details--set-metadata-visibility))
      (insert (propertize "\n对话" 'face 'bold)
              (propertize "  ·  agent 左 / 用户右  ·  思考与工具调用不在此展示\n\n" 'face 'shadow))
      (cl-loop for turn in ashub-details--turns for i from 0
               do (ashub-details--insert-message turn i width))
      (goto-char (or (and index (text-property-any (point-min) (point-max) 'ashub-turn-index index)) (point-min)))
      (set-buffer-modified-p nil))))

(defun ashub-details--resize (frame)
  "Reflow visible detail windows in FRAME from cached text only."
  (dolist (window (window-list frame 'nomini))
    (with-current-buffer (window-buffer window)
      (when (and (derived-mode-p 'ashub-details-mode) ashub-details--session
                 (not (= (window-body-width window) (or ashub-details--width 0))))
        (ashub-details--render (window-body-width window))))))

(defun ashub-details-refresh ()
  "Reflow the cached conversation without re-reading history or using models."
  (interactive)
  (ashub-details--render))

(defvar ashub-details-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "m") #'ashub-details-toggle-metadata)
    (define-key map (kbd "g") #'ashub-details-refresh)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "C-c C-w") #'ashub-details-copy-conversation)
    map))

(define-derived-mode ashub-details-mode special-mode "ashub details"
  "Read saved dialogue: agent left, user right; m toggles full metadata.
Each message has a copy button for its exact original text.  C-c C-w
copies the original conversation, without display-only reflow."
  (setq-local truncate-lines t display-line-numbers nil)
  (setq-local header-line-format "  q 返回   m 详细信息   TAB 切换按钮   C-c C-w 复制原始对话")
  (add-to-invisibility-spec 'ashub-details-metadata))

(defun ashub-details-show (session conversation stale)
  "Show SESSION's saved CONVERSATION with compact metadata and chat layout.
STALE records whether source refresh failed.  This function only renders."
  (let ((buffer (get-buffer-create "*ashub details*")))
    (with-current-buffer buffer
      (ashub-details-mode)
      (setq ashub-details--session session ashub-details--conversation conversation
            ashub-details--turns (ashub-details--parse conversation) ashub-details--stale stale)
      (ashub--display-full-buffer buffer)
      (ashub-details--render))))

(add-hook 'window-size-change-functions #'ashub-details--resize)

(provide 'ashub-details)
;;; ashub-details.el ends here
