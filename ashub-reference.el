;;; ashub-reference.el --- Reference saved sessions from any agent -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Package-Requires: ((emacs "29.1"))
;; Version: 0.1.0
;; Keywords: tools, processes

;;; Commentary:
;; Export one saved session's user/assistant text to a private Markdown file
;; and insert a file reference into the current agent's draft.  Exporting
;; only reads history; nothing is sent until the user submits the draft.

;;; Code:
(require 'ashub-core)
(require 'ashub-sources)
(require 'ashub-open)

(defvar ashub--states)
(defvar emacs-pi-reference-providers)
(defvar emacs-dsh-reference-providers)
(declare-function ashub-mode "ashub")
(declare-function ashub-refresh "ashub")
(declare-function ashub--all-sessions "ashub")
(declare-function ashub--preview-text "ashub")
(declare-function emacs-pi-history-session-excerpt "emacs-pi-history")
(declare-function emacs-pi-insert-file "emacs-pi")
(declare-function emacs-dsh-read-session "emacs-dsh")
(declare-function emacs-dsh-insert-file "emacs-dsh")
(declare-function ghostel-paste-string "ghostel")

(defcustom ashub-reference-directory
  (expand-file-name "ashub/refs" (or (getenv "XDG_CACHE_HOME") "~/.cache"))
  "Private directory for exported session references."
  :type 'directory :group 'ashub)
(defcustom ashub-reference-max-chars 200000
  "Approximate dialogue characters per reference; the middle is omitted beyond it."
  :type 'integer :group 'ashub)
(defcustom ashub-reference-dsh-max-messages 1000
  "Latest DSH messages to request; the Host offers no older pages."
  :type 'integer :group 'ashub)

(defun ashub-reference--python (args &optional input)
  "Run the scanner with ARGS and optional stdin INPUT; return its stdout."
  (let ((program (or (executable-find ashub-python-program)
                     (user-error "Missing Python 3.9+: configure ashub-python-program")))
        (errors (make-temp-file "ashub-reference-errors"))
        (coding-system-for-read 'utf-8) (coding-system-for-write 'utf-8)
        (default-directory temporary-file-directory))
    (unwind-protect
        (with-temp-buffer
          (when input (insert input))
          (let ((status (apply #'call-process-region (point-min) (point-max) program t
                               (list t errors) nil "-B" ashub--scanner-file args)))
            (unless (eql status 0)
              (user-error "%s" (let ((text (with-temp-buffer
                                             (insert-file-contents errors)
                                             (string-trim (buffer-string)))))
                                 (if (string-empty-p text) (format "Scanner failed: %s" status) text))))
            (buffer-string)))
      (delete-file errors))))

(defun ashub-reference--await (start)
  "Call START with success/error callbacks and wait for one; return or signal.
START returns a cancel function, called if waiting is interrupted."
  (let (done value failure cancel)
    (unwind-protect
        (progn
          (setq cancel (funcall start (lambda (result) (setq done t value result))
                                (lambda (error) (setq done t failure error))))
          ;; ponytail: blocks until the client's own timeout; C-g cancels.
          (while (not done) (accept-process-output nil 0.05))
          (when failure (user-error "%s" failure))
          value)
      (unless done (when (functionp cancel) (funcall cancel))))))

(defun ashub-reference--render (session turns body notes)
  "Render SESSION's TURNS or preformatted BODY, with NOTES, through the scanner."
  (ashub-reference--python
   (list "render" "--max-chars" (number-to-string ashub-reference-max-chars))
   (json-serialize
    (list :meta (list :agent (symbol-name (ashub-session-agent session))
                      :id (ashub-session-id session)
                      :cwd (or (ashub-session-cwd session) :null)
                      :title (or (ashub-session-title session) :null)
                      :source (or (ashub-session-path session) :null)
                      :notes (vconcat notes))
          :turns (if turns
                     (vconcat (mapcar (lambda (turn)
                                        (list :role (symbol-name (plist-get turn :role))
                                              :text (plist-get turn :text)
                                              :time (or (plist-get turn :time) :null)))
                                      turns))
                   :null)
          :body (or body :null)))))

(defun ashub-reference-markdown (session)
  "Return SESSION's saved user/assistant text as reference Markdown."
  (pcase (ashub-session-agent session)
    ((and agent (or 'claude 'codex 'hermes))
     (ashub-reference--python
      (list "export" (symbol-name agent)
            (ashub--root (plist-get (ashub-session-source session) :root))
            (ashub-session-id session)
            "--max-chars" (number-to-string ashub-reference-max-chars))))
    ('pi
     (require 'emacs-pi nil t)
     (unless (fboundp 'emacs-pi-history-session-excerpt)
       (user-error "Load emacs-pi with emacs-pi-history-session-excerpt"))
     (ashub-reference--render
      session nil (emacs-pi-history-session-excerpt
                   (list :path (ashub-session-path session)) ashub-reference-max-chars)
      nil))
    ('dsh
     (require 'emacs-dsh nil t)
     (unless (fboundp 'emacs-dsh-read-session)
       (user-error "Load API-capable emacs-dsh (emacs-dsh-read-session missing)"))
     (ashub--dsh-source-check session)
     (let ((value (ashub-reference--await
                   (lambda (on-success on-error)
                     (emacs-dsh-read-session (ashub-session-id session) on-success
                                             :on-error on-error
                                             :max-messages ashub-reference-dsh-max-messages)))))
       (ashub-reference--render
        session (plist-get value :messages) nil
        (list (format "Read at most the latest %d DSH messages; earlier ones are not included"
                      (plist-get value :max-messages))))))
    (agent (user-error "No reference export for %s" agent))))

(defun ashub-reference-write (session markdown)
  "Write MARKDOWN for SESSION to a private reference file and return its path."
  (let ((file (expand-file-name
               (format "%s-%s.md" (ashub-session-agent session)
                       (replace-regexp-in-string "[^[:alnum:]_.-]" "_" (ashub-session-id session)))
               ashub-reference-directory)))
    (with-file-modes #o700 (make-directory ashub-reference-directory t))
    (set-file-modes ashub-reference-directory #o700)
    (with-file-modes #o600
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region markdown nil file nil 'silent)))
    (set-file-modes file #o600)
    file))

(defun ashub-reference--sessions ()
  "Return referenceable sessions newest first, reading history if needed."
  (require 'ashub)
  (with-current-buffer (get-buffer-create "*ashub*")
    (unless (derived-mode-p 'ashub-mode) (ashub-mode))
    (when (zerop (hash-table-count ashub--states)) (ashub-refresh))
    (let ((deadline (+ (float-time) ashub-scan-timeout)))
      (while (and (< (float-time) deadline)
                  (let (loading)
                    (maphash (lambda (_key state)
                               (when (eq (plist-get state :status) 'loading) (setq loading t)))
                             ashub--states)
                    loading))
        (message "ashub：正在读取历史会话…")
        (accept-process-output nil 0.05)))
    (ashub-sort-sessions
     (seq-filter (lambda (session) (ashub-session-visible-p session nil nil ""))
                 (ashub--all-sessions)))))

(defun ashub-reference--label (session sessions)
  "Return a one-line completion label for SESSION among SESSIONS."
  (format "%-6s %-16s  %s  %s  %s"
          (ashub-session-agent session)
          (if-let* ((seconds (ashub-session-last-active session)))
              (format-time-string "%Y-%m-%d %H:%M" (seconds-to-time seconds))
            "时间未知")
          (ashub--middle (ashub-session-project session) 28)
          (truncate-string-to-width (ashub--one-line (ashub--preview-text session)) 60 nil nil "…")
          (ashub-short-id session sessions)))

(defun ashub-reference-read-session ()
  "Choose a saved session from every configured agent, newest first."
  (let* ((sessions (or (ashub-reference--sessions)
                       (user-error "没有可引用的会话；M-x ashub 后按 ! 查看诊断")))
         (seen (make-hash-table :test #'equal))
         (choices (mapcar (lambda (session)
                            (let* ((label (ashub-reference--label session sessions))
                                   (count (puthash label (1+ (gethash label seen 0)) seen)))
                              (cons (if (> count 1) (format "%s #%d" label count) label) session)))
                          sessions))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      '(metadata (category . ashub-session)
                                 (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action action choices string predicate)))))
    (cdr (assoc (completing-read "引用会话：" table nil t) choices))))

;;;###autoload
(defun ashub-reference-provider (&optional _root)
  "Choose a saved session and return the path of its exported reference."
  (let ((session (ashub-reference-read-session)))
    (message "ashub：正在导出 %s 会话…" (ashub-session-agent session))
    (prog1 (ashub-reference-write session (ashub-reference-markdown session))
      (message nil))))

;;;###autoload
(defun ashub-insert-reference ()
  "Insert a file reference to a saved session from any agent at point.
Ghostel terminals get a bracketed paste; Pi and DSH drafts get their own
@file reference.  Nothing is submitted."
  (interactive)
  (let ((target (current-buffer)) (path (ashub-reference-provider)))
    (with-current-buffer target
      (cond ((derived-mode-p 'ghostel-mode)
             ;; ponytail: "@path" is Claude's file syntax; other terminal agents read it as a path.
             (ghostel-paste-string (concat "@" path " ")))
            ((bound-and-true-p emacs-pi--session) (emacs-pi-insert-file path))
            ((derived-mode-p 'emacs-dsh-chat-mode) (emacs-dsh-insert-file path))
            (t (insert path))))))

;;;###autoload
(with-eval-after-load 'emacs-pi
  (add-to-list 'emacs-pi-reference-providers '("ashub" . ashub-reference-provider)))
;;;###autoload
(with-eval-after-load 'emacs-dsh
  (add-to-list 'emacs-dsh-reference-providers '("ashub" . ashub-reference-provider)))

(provide 'ashub-reference)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; ashub-reference.el ends here
