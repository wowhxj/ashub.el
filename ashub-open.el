;;; ashub-open.el --- Exact-session restore dispatch -*- lexical-binding: t; -*-

;;; Commentary:
;; Explicit user actions only.  No prompt sending, shell command strings,
;; auto-installation, profile fallback, unarchiving or disk mapping cache.

;;; Code:
(require 'ashub-core)
(declare-function ghostel-exec "ghostel" (buffer program &optional args identity))
(declare-function emacs-pi-open-session "emacs-pi")
(declare-function emacs-dsh-open-session "emacs-dsh")
(declare-function emacs-dsh--source-identity "emacs-dsh" ())
(defvar ghostel-module-auto-install)

(defcustom ashub-open-timeout 60 "Seconds before a native restore request times out."
  :type 'number :group 'ashub)
(defvar ashub--instances (make-hash-table :test #'equal)
  "Hub-owned terminal buffers/processes, indexed by full source-qualified key.")
(defvar ashub--opening (make-hash-table :test #'equal) "Pending native open requests.")
(defvar ashub--directory-overrides (make-hash-table :test #'equal)
  "User-selected project directory overrides; memory only.")

(defun ashub--local-directory-p (directory)
  "Whether DIRECTORY is an existing absolute local directory."
  (and (stringp directory) (file-name-absolute-p directory)
       (not (file-remote-p directory)) (file-directory-p directory)))

(defun ashub--restore-directory (session)
  "Get SESSION's original cwd or explicitly ask for a local replacement."
  (let* ((key (ashub-session-key session))
         (directory (or (gethash key ashub--directory-overrides) (ashub-session-cwd session))))
    (unless (ashub--local-directory-p directory)
      (setq directory
            (read-directory-name
             (format "%s：项目目录缺失或不可用，请选择恢复目录：" (ashub-session-id session))
             (expand-file-name "~/") nil t))
      (unless (ashub--local-directory-p directory)
        (user-error "请选择现有的本地绝对目录；不支持 TRAMP 恢复"))
      (puthash key (file-name-as-directory (file-truename directory)) ashub--directory-overrides))
    (file-name-as-directory (file-truename directory))))

(defun ashub--terminal-command (session directory)
  "Build distinct argv and source-bound environment for SESSION in DIRECTORY."
  (let* ((source (ashub-session-source session))
         (agent (ashub-session-agent session))
         (id (ashub-session-id session))
         (root (ashub--root (plist-get source :root)))
         (variable (pcase agent ('claude "CLAUDE_CONFIG_DIR") ('codex "CODEX_HOME")
                          ('hermes "HERMES_HOME")))
         (program (or (plist-get source :program) (symbol-name agent)))
         (environment (copy-sequence process-environment)))
    (unless (and (stringp id) (not (string-empty-p id)) (not (string-prefix-p "-" id)))
      (user-error "Invalid exact session ID"))
    (unless variable (user-error "No terminal restore adapter for %s" agent))
    (dolist (entry (plist-get source :environment))
      (unless (and (stringp entry) (string-match "\\`\\([^=]+\\)=\\(.*\\)\\'" entry))
        (user-error "Invalid source environment entry; expected NAME=VALUE"))
      (let ((name (match-string 1 entry)) (value (match-string 2 entry)))
        (when (and (equal name variable) (not (equal (ashub--root value) root)))
          (user-error "%s cannot point to another source" variable))
        (setq environment (cons entry (cl-remove-if
                                       (lambda (old) (string-prefix-p (concat name "=") old))
                                       environment)))))
    (setq environment (cons (concat variable "=" root)
                            (cl-remove-if (lambda (old) (string-prefix-p (concat variable "=") old))
                                          environment)))
    (list program
          (append (plist-get source :args)
                  (pcase agent
                    ('claude (list "--resume" id))
                    ('codex (list "resume" id "--cd" directory))
                    ('hermes (list "--resume" id "--in" directory))))
          environment)))

(defun ashub--open-terminal (session directory on-ready)
  "Restore SESSION through ghostel in DIRECTORY, preserving exact argv.
Invoke ON-READY with its buffer.  A live process proves launch, not that
the agent has accepted the requested resume."
  (let* ((key (ashub-session-key session)) (old (gethash key ashub--instances))
         (buffer (plist-get old :buffer)) (process (plist-get old :process)))
    (if (and (buffer-live-p buffer) (process-live-p process))
        (funcall on-ready buffer)
      (pcase-let* ((`(,program ,args ,environment) (ashub--terminal-command session directory))
                   (process-environment environment)
                   (exec-path (append (parse-colon-path (getenv "PATH")) exec-path))
                   (executable (executable-find program)))
        (unless executable
          (user-error "Missing %s executable; install/configure it yourself (:program)" program))
        (if ashub-terminal-open-function
            (funcall ashub-terminal-open-function session executable args directory environment on-ready)
          (require 'ghostel nil t)
          (unless (fboundp 'ghostel-exec)
            (user-error "Missing ghostel-exec; load ghostel or configure ashub-terminal-open-function"))
          (unless (buffer-live-p buffer)
            (setq buffer (generate-new-buffer
                          (format "*ashub %s %s*" (ashub-session-agent session)
                                  (substring (ashub-session-id session) 0
                                             (min 12 (length (ashub-session-id session))))))))
          (with-current-buffer buffer
            (setq default-directory directory)
            (let ((ghostel-module-auto-install nil))
              (setq process
                    (ghostel-exec buffer executable args
                                  `((kind . ashub) (session . ,key)
                                    (command . (,executable . ,args)))))))
          (unless (process-live-p process) (user-error "Ghostel did not start a live process"))
          (puthash key (list :buffer buffer :process process) ashub--instances)
          (funcall on-ready buffer))))))

(defun ashub--dsh-source-check (session)
  "Fail closed if SESSION belongs to a different authenticated Host generation."
  (unless (and (fboundp 'emacs-dsh--source-identity)
               (equal (plist-get (ashub-session-metadata session) :native-source)
                      (emacs-dsh--source-identity)))
    (user-error "DSH Host identity changed/unavailable; refresh before restoring this source")))

(defun ashub-open-session (session)
  "Restore selected SESSION, without sending any message.
Native clients own their verified readiness/reuse lifecycle.  Terminal
clients reuse only live processes created by this Hub, never external ones."
  (when (eq (ashub-session-archived session) t)
    (user-error "Archived session: unarchive in its own client, then refresh; Hub will not unarchive"))
  (let* ((key (ashub-session-key session))
         (source (ashub-session-source session))
         (directory (ashub--restore-directory session))
         (agent (ashub-session-agent session)))
    (when (gethash key ashub--opening)
      (user-error "This session is already opening; wait for readiness or timeout"))
    (unless (or (eq agent 'dsh) (file-directory-p (ashub--root (plist-get source :root))))
      (user-error "Storage source unavailable; refusing to create or use a substitute profile"))
    (if (and (memq agent '(claude codex hermes)) (not (plist-get source :open-function)))
        (ashub--open-terminal
         session directory (lambda (buffer)
                             (pop-to-buffer buffer)
                             (message "恢复参数已提交；请在 agent 界面确认选中会话，Hub 未发送消息")))
      (let ((token (list nil)) timer cancel finished)
        (puthash key token ashub--opening)
        (cl-labels
            ((finish (buffer error)
               (unless finished
                 (setq finished t)
                 (when (timerp timer) (cancel-timer timer))
                 (when (eq (gethash key ashub--opening) token) (remhash key ashub--opening))
                 (if error (message "ashub 恢复失败：%s" error)
                   (if (not (buffer-live-p buffer)) (message "ashub: client returned a dead buffer")
                     (pop-to-buffer buffer) (message "客户端已确认会话就绪；Hub 未发送消息"))))))
          (setq timer (run-at-time ashub-open-timeout nil
                                   (lambda ()
                                     (finish nil "恢复超时；请求可能仍在客户端中，未确认就绪")
                                     (when (functionp cancel) (funcall cancel)))))
          (condition-case err
              (setq cancel
                    (cond
                     ((plist-get source :open-function)
                      (funcall (plist-get source :open-function) session directory
                               (lambda (buffer) (finish buffer nil))
                               (lambda (error) (finish nil error))))
                     ((eq agent 'pi)
                      (require 'emacs-pi nil t)
                      (unless (fboundp 'emacs-pi-open-session)
                        (user-error "Load API-capable emacs-pi (emacs-pi-open-session missing)"))
                      (emacs-pi-open-session
                       (ashub-session-path session) :directory directory
                       :session-directory (ashub--root (plist-get source :root)) :display 'none
                       :on-ready (lambda (buffer) (finish buffer nil))
                       :on-error (lambda (error) (finish nil error))))
                     ((eq agent 'dsh)
                      (require 'emacs-dsh nil t)
                      (unless (fboundp 'emacs-dsh-open-session)
                        (user-error "Load API-capable emacs-dsh (emacs-dsh-open-session missing)"))
                      (ashub--dsh-source-check session)
                      (emacs-dsh-open-session
                       (ashub-session-id session) :directory directory :display 'none
                       :on-ready (lambda (buffer)
                                   (condition-case err
                                       (progn (ashub--dsh-source-check session) (finish buffer nil))
                                     (error (finish nil (error-message-string err)))))
                       :on-error (lambda (error) (finish nil error))))
                     (t (user-error "No restore adapter for %s" agent))))
            (error (finish nil (error-message-string err)))))))))

(provide 'ashub-open)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; ashub-open.el ends here
