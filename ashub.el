;;; ashub.el --- Browse and resume agent sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Version: 0.1.0
;; URL: https://github.com/wowhxj/ashub.el
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, processes, convenience

;;; Commentary:
;; M-x ashub browses configured Claude, Codex, Pi, DSH and Hermes history.
;; Loading/refreshing never resumes a session.  RET is the explicit restore
;; action.  Local scans require Python 3.9+; Pi and DSH use public client APIs.

;;; Code:
(require 'ashub-core)
(require 'ashub-sources)
(require 'ashub-open)
(require 'help-mode)
(require 'text-property-search)

(defvar-local ashub--states nil "Source state table; results are memory-only.")
(defvar-local ashub--generation 0 "Refresh generation, rejects late callbacks.")
(defvar-local ashub--agent-filter nil)
(defvar-local ashub--project-filter nil)
(defvar-local ashub--query "")
(defvar-local ashub--grouping nil)
(defvar-local ashub--collapsed nil)
(defvar-local ashub--expanded nil)
(defvar-local ashub--status "")

(defun ashub--source-label (source)
  "Return an unambiguous readable label for SOURCE."
  (ashub--one-line
   (or (plist-get source :label)
       (format "%s:%s%s" (plist-get source :agent)
               (if (eq (plist-get source :agent) 'dsh) (plist-get source :root)
                 (abbreviate-file-name (ashub--root (plist-get source :root))))
               (if (plist-get source :profile) (format " [%s]" (plist-get source :profile)) "")))))

(defun ashub--all-sessions ()
  "Return all retained sessions in this Hub, without filtering."
  (let (items)
    (when ashub--states
      (maphash (lambda (_key state) (setq items (append (plist-get state :items) items))) ashub--states))
    items))

(defun ashub--visible-sessions ()
  "Return filtered sessions ordered by last interaction."
  (ashub-sort-sessions
   (seq-filter (lambda (item)
                 (ashub-session-visible-p item ashub--agent-filter ashub--project-filter ashub--query))
               (ashub--all-sessions))))

(defun ashub--group-name (session)
  "Return SESSION's group label in the selected grouping."
  (if (eq ashub--grouping 'project)
      (ashub-session-project session)
    (symbol-name (ashub-session-agent session))))

(defun ashub--stale-p (session)
  "Whether SESSION is retained from a failed/incomplete refresh."
  (let ((state (gethash (ashub-source-key (ashub-session-source session)) ashub--states)))
    (or (eq (plist-get state :status) 'stale)
        (member (ashub-session-key session) (plist-get state :stale-keys)))))

(defun ashub--insert-row (session sessions)
  "Insert single-line table row for SESSION among SESSIONS."
  (let* ((start (point)) (key (ashub-session-key session))
         (width (max 40 (window-body-width (get-buffer-window (current-buffer)))))
         (id (ashub-short-id session sessions))
         (time (if-let* ((seconds (ashub-session-last-active session)))
                   (format-time-string "%Y-%m-%d %H:%M" (seconds-to-time seconds)) "时间未知"))
         (project-width (max 10 (min 28 (/ width 5))))
         (preview (ashub--one-line (or (ashub-session-first-message session) "[首条用户消息未知]")))
         (prefix (format (format "  %%-7s %%-16s %%-%ds %%-%ds " (max 8 (length id)) project-width)
                         (ashub-session-agent session) time id
                         (ashub--middle (ashub-session-project session) project-width))))
    (insert prefix
            (truncate-string-to-width preview (max 12 (- width (string-width prefix) 5)) nil nil "…")
            (if (ashub--stale-p session) " [旧]" "") "\n")
    (when (gethash key ashub--expanded)
      (insert "    ┊ " (replace-regexp-in-string "\n" "\n    ┊ "
                                                 (or (ashub-session-first-message session)
                                                     "[首条用户消息未知]")) "\n"))
    (add-text-properties start (point) (list 'ashub-session session 'ashub-key key
                                             'mouse-face 'highlight 'rear-nonsticky t))))

(defun ashub--render ()
  "Redraw the Hub, preserving selected identity and window position."
  (let* ((key (get-text-property (point) 'ashub-key))
         (column (current-column)) (old-point (point))
         (window (get-buffer-window (current-buffer)))
         (window-start-key (and window (get-text-property (window-start window) 'ashub-key)))
         (sessions (ashub--visible-sessions))
         (groups (make-hash-table :test #'equal)) order pending problems
         (inhibit-read-only t))
    (dolist (session sessions)
      (let ((name (ashub--group-name session)))
        (unless (gethash name groups) (push name order))
        (puthash name (cons session (gethash name groups)) groups)))
    (when ashub--states
      (maphash
       (lambda (_key state)
         (let ((status (plist-get state :status)))
           (when (eq status 'loading) (push (ashub--source-label (plist-get state :source)) pending))
           (when (memq status '(error stale partial))
             (push (format "%s%s" (ashub--source-label (plist-get state :source))
                           (if (eq status 'stale) "（旧数据／刷新失败）" "")) problems))))
       ashub--states))
    (setq ashub--status
          (format "ashub  %d/%d 条  %s%s"
                  (length sessions) (length (ashub--all-sessions))
                  (if pending (format "扫描中：%s  " (string-join (nreverse pending) ", ")) "")
                  (if problems (format "结果不完整：%s  [! 诊断]" (string-join (nreverse problems) ", ")) "")))
    (setq header-line-format `(:eval (propertize ashub--status 'face
                                                 ',(if problems 'warning 'mode-line))))
    (erase-buffer)
    (insert (propertize "Agent Session Hub\n" 'face 'bold))
    (insert (format "分组:%s  agent:%s  项目:%s  搜索:%s\n"
                    ashub--grouping (or ashub--agent-filter "全部")
                    (ashub--one-line (or ashub--project-filter "全部")) (ashub--one-line ashub--query)))
    (insert "RET 恢复  / 搜索  a agent  p 项目  C 清除过滤  c 分组  TAB 折叠  g 刷新  e 展开  d 详情  ! 诊断\n\n")
    (if (null sessions) (insert "没有符合当前过滤条件的会话；请查看顶部扫描状态及诊断。\n")
      (dolist (name (nreverse order))
        (let* ((start (point)) (folded (gethash name ashub--collapsed))
               (group (nreverse (gethash name groups))))
          (insert (propertize (format "%s %s (%d)\n" (if folded "+" "−") (ashub--one-line name)
                                      (length group)) 'face 'bold))
          (add-text-properties start (point) (list 'ashub-group name 'ashub-key (list 'group name)))
          (unless folded (dolist (session group) (ashub--insert-row session sessions))))))
    (goto-char (point-min))
    (let ((match (and key (text-property-search-forward 'ashub-key key #'equal))))
      (if match
          (progn (goto-char (prop-match-beginning match)) (move-to-column column))
        (goto-char (min old-point (point-max)))))
    (when (and window window-start-key)
      (save-excursion
        (goto-char (point-min))
        (when-let* ((match (text-property-search-forward 'ashub-key window-start-key #'equal)))
          (set-window-start window (prop-match-beginning match) t))))))

(defun ashub--cancel-scans ()
  "Cancel background work and reject callbacks from the old generation."
  (cl-incf ashub--generation)
  (when ashub--states
    (maphash (lambda (_key state)
               (when (functionp (plist-get state :cancel))
                 (funcall (plist-get state :cancel)))
               (setf (plist-get state :cancel) nil)
               (when (eq (plist-get state :status) 'loading)
                 (setf (plist-get state :status) (if (plist-get state :loaded) 'stale 'error)
                       (plist-get state :diagnostics) '("扫描已取消；未确认数据已刷新"))))
             ashub--states)))

(defun ashub--accept-source (key items diagnostics failure)
  "Commit source KEY's ITEMS/DIAGNOSTICS, preserving old results on FAILURE."
  (let* ((state (gethash key ashub--states)) (old (plist-get state :items)))
    (setf (plist-get state :cancel) nil (plist-get state :stale-keys) nil)
    (if failure
        (setf (plist-get state :status) (if (plist-get state :loaded) 'stale 'error)
              (plist-get state :diagnostics) (list failure))
      (let ((seen (make-hash-table :test #'equal)) unique)
        (dolist (session items)
          (unless (equal (ashub-source-key (ashub-session-source session)) key)
            (error "Adapter returned a session from another source"))
          (unless (gethash (ashub-session-key session) seen)
            (puthash (ashub-session-key session) t seen) (push session unique)))
        (when diagnostics
          (dolist (session old)
            (unless (gethash (ashub-session-key session) seen)
              (push (ashub-session-key session) (plist-get state :stale-keys))
              (push session unique))))
        (setf (plist-get state :items) (nreverse unique)
              (plist-get state :loaded) t
              (plist-get state :status) (if diagnostics 'partial 'ok)
              (plist-get state :diagnostics) diagnostics)))
    (puthash key state ashub--states)
    (ashub--render)))

(defun ashub-refresh ()
  "Asynchronously refresh all configured sources without resuming anything."
  (interactive)
  (let ((sources (ashub-configured-sources)) (old ashub--states)
        (buffer (current-buffer)))
    (ashub--cancel-scans)
    (setq ashub--states (make-hash-table :test #'equal))
    (dolist (source sources)
      (let* ((key (ashub-source-key source))
             (state (copy-sequence (and old (gethash key old)))))
        (setf (plist-get state :source) source (plist-get state :status) 'loading
              (plist-get state :diagnostics) nil (plist-get state :cancel) nil)
        (puthash key state ashub--states)))
    (ashub--render)
    (let ((generation ashub--generation))
      (dolist (source sources)
        (let* ((key (ashub-source-key source))
               (cancel
                (ashub-scan-source
                 source
                 (lambda (items diagnostics)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (when (= generation ashub--generation)
                         (condition-case err
                             (ashub--accept-source key items diagnostics nil)
                           (error (ashub--accept-source key nil nil (error-message-string err))))))))
                 (lambda (error)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (when (= generation ashub--generation)
                         (ashub--accept-source key nil nil error))))))))
          (when (eq (plist-get (gethash key ashub--states) :status) 'loading)
            (setf (plist-get (gethash key ashub--states) :cancel) cancel)))))))

(defun ashub--session-at-point ()
  "Return current row's session, or signal a helpful error."
  (or (get-text-property (point) 'ashub-session) (user-error "请先选择一条会话")))

(defun ashub-open ()
  "Resume the exact session at point, through its configured client."
  (interactive) (ashub-open-session (ashub--session-at-point)))

(defun ashub-toggle-group ()
  "Collapse or expand point's group."
  (interactive)
  (let ((name (or (get-text-property (point) 'ashub-group)
                  (ashub--group-name (ashub--session-at-point)))))
    (puthash name (not (gethash name ashub--collapsed)) ashub--collapsed)
    (ashub--render)))

(defun ashub-change-grouping ()
  "Toggle agent/project grouping while retaining filters."
  (interactive)
  (setq ashub--grouping (if (eq ashub--grouping 'agent) 'project 'agent))
  (clrhash ashub--collapsed) (ashub--render))

(defun ashub-filter-agent ()
  "Set or clear agent filter with completion."
  (interactive)
  (let ((choice (completing-read "Agent：" '("全部" "claude" "codex" "pi" "dsh" "hermes") nil t)))
    (setq ashub--agent-filter
          (unless (or (string-empty-p (string-trim choice)) (equal choice "全部"))
            (intern choice))))
  (ashub--render))

(defun ashub-filter-project ()
  "Set a literal project path filter, with history-based completion."
  (interactive)
  (let ((choice (completing-read
                 "项目路径（可输入片段）："
                 (cons "全部" (delete-dups (delq nil (mapcar #'ashub-session-cwd (ashub--all-sessions)))))
                 nil nil nil nil ashub--project-filter)))
    (setq ashub--project-filter (unless (or (equal choice "全部") (string-empty-p choice)) choice)))
  (ashub--render))

(defun ashub-search ()
  "Live literal search of agent, full ID, cwd and full first user message.
Cancel restores the previous search.  No new scan or restore is triggered."
  (interactive)
  (let ((hub (current-buffer)) (old ashub--query) accepted)
    (unwind-protect
        (progn
          (minibuffer-with-setup-hook
              (lambda ()
                (add-hook 'post-command-hook
                          (lambda ()
                            (let ((query (minibuffer-contents-no-properties)))
                              (when (buffer-live-p hub)
                                (with-current-buffer hub (setq ashub--query query) (ashub--render)))))
                          nil t))
            (setq ashub--query (read-from-minibuffer "搜索：" old)))
          (setq accepted t))
      (unless accepted (setq ashub--query old))
      (ashub--render))))

(defun ashub-clear-filters ()
  "Clear search/agent/project filters without reading history again."
  (interactive)
  (setq ashub--query "" ashub--agent-filter nil ashub--project-filter nil)
  (ashub--render))

(defun ashub-toggle-preview ()
  "Toggle current session's full first-message preview."
  (interactive)
  (let ((key (ashub-session-key (ashub--session-at-point))))
    (puthash key (not (gethash key ashub--expanded)) ashub--expanded)
    (ashub--render)))

(defun ashub-details ()
  "Display full identity and known metadata, not a complete transcript."
  (interactive)
  (let ((session (ashub--session-at-point)))
    (with-help-window "*ashub details*"
      (princ (format "Agent: %s\nSession ID: %s\nSource: %s\nStorage path: %s\nProject: %s\n"
                     (ashub-session-agent session) (ashub-session-id session)
                     (ashub--source-label (ashub-session-source session))
                     (or (ashub-session-path session) "unknown")
                     (or (ashub-session-cwd session) "unknown")))
      (princ (format "Storage root: %s\nProfile label: %S\n"
                     (plist-get (ashub-session-source session) :root)
                     (plist-get (ashub-session-source session) :profile)))
      (princ (format "Origin: %S\nInteraction time: %S\nTime source: %S\nInternal: %S\nEmpty: %S\nArchived: %S\nData: %s\n"
                     (ashub-session-origin session) (ashub-session-last-active session)
                     (ashub-session-time-source session) (ashub-session-internal session)
                     (ashub-session-empty session) (ashub-session-archived session)
                     (if (ashub--stale-p session) "stale; refresh failed" "see source status")))
      (when (ashub-session-title session)
        (princ (format "Title (not a raw first message): %s\n" (ashub-session-title session))))
      (princ (format "\nFirst user message:\n%s\n"
                     (or (ashub-session-first-message session) "[unknown]"))))))

(defun ashub-copy-id ()
  "Copy the full selected session ID."
  (interactive) (kill-new (ashub-session-id (ashub--session-at-point))) (message "已复制完整 session ID"))

(defun ashub-copy-project ()
  "Copy the selected session's recorded project directory."
  (interactive)
  (let ((cwd (ashub-session-cwd (ashub--session-at-point))))
    (unless cwd (user-error "该会话未记录项目目录")) (kill-new cwd) (message "已复制项目路径")))

(defun ashub-diagnostics ()
  "Show per-source availability and partial-scan diagnostics."
  (interactive)
  (let ((states ashub--states))
    (with-help-window "*ashub diagnostics*"
      (maphash (lambda (_key state)
                 (princ (format "%s\nStatus: %s; retained records: %d\n"
                                (ashub--source-label (plist-get state :source))
                                (plist-get state :status) (length (plist-get state :items))))
                 (dolist (error (plist-get state :diagnostics)) (princ (format "  %s\n" error)))
                 (princ "\n")) states))))

(defun ashub-quit ()
  "Cancel scans and bury the Hub.  Do not stop running chat buffers."
  (interactive) (ashub--cancel-scans) (quit-window))

(defvar ashub-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (entry '(("RET" . ashub-open) ("/" . ashub-search) ("a" . ashub-filter-agent)
                     ("p" . ashub-filter-project) ("c" . ashub-change-grouping)
                     ("TAB" . ashub-toggle-group) ("g" . ashub-refresh)
                     ("e" . ashub-toggle-preview) ("d" . ashub-details)
                     ("w" . ashub-copy-id) ("W" . ashub-copy-project)
                     ("!" . ashub-diagnostics) ("C" . ashub-clear-filters)
                     ("C-c C-k" . ashub-clear-filters)
                     ("q" . ashub-quit)))
      (define-key map (kbd (car entry)) (cdr entry)))
    map))

(define-derived-mode ashub-mode special-mode "ashub"
  "Browse historical agent sessions, without taking over external processes."
  (setq-local truncate-lines t)
  (setq ashub--states (make-hash-table :test #'equal)
        ashub--collapsed (make-hash-table :test #'equal)
        ashub--expanded (make-hash-table :test #'equal)
        ashub--grouping ashub-group-by)
  (add-hook 'kill-buffer-hook #'ashub--cancel-scans nil t))

;;;###autoload
(defun ashub ()
  "Open Agent Session Hub and read configured history asynchronously."
  (interactive)
  (let ((buffer (get-buffer-create "*ashub*")))
    (pop-to-buffer buffer)
    (unless (derived-mode-p 'ashub-mode) (ashub-mode))
    (ashub-refresh)))

(provide 'ashub)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; ashub.el ends here
