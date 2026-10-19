;;; ashub-open.el --- Exact-session restore dispatch -*- lexical-binding: t; -*-

;;; Commentary:
;; Explicit user actions only.  No prompt sending, shell command strings,
;; auto-installation, profile fallback, unarchiving or disk mapping cache.

;;; Code:
(require 'ashub-core)
(declare-function ghostel-exec "ghostel" (buffer program &optional args identity))
(declare-function emacs-pi-open-session "emacs-pi")
(declare-function emacs-dsh-open-session "emacs-dsh")
(declare-function emacs-pi-create-session "emacs-pi")
(declare-function emacs-dsh-create-session "emacs-dsh")
(declare-function emacs-dsh--source-identity "emacs-dsh" ())
(defvar ghostel-module-auto-install)

(defcustom ashub-open-timeout 60 "Seconds before a creation or restore request times out."
  :type 'number :group 'ashub)
(defvar ashub--instances (make-hash-table :test #'equal)
  "Hub-owned terminal buffers/processes, indexed by full source-qualified key.")
(defvar ashub--opening (make-hash-table :test #'equal) "Pending restore tokens with display labels.")
(defvar ashub-open-state-change-hook nil
  "Hook run when a session starts or finishes restoring.")

(defun ashub--opening-summary ()
  "Return labels of pending restores, or nil when none are pending."
  (let (labels)
    (maphash (lambda (_key token)
               (push (concat (if (eq (plist-get token :operation) 'create) "正在新建：" "正在恢复：")
                             (plist-get token :label)) labels)) ashub--opening)
    (when labels (string-join (nreverse labels) ", "))))
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

(defun ashub--terminal-command-for-source (source directory &optional id)
  "Build source-bound CLI argv; ID selects restore, nil selects a fresh session."
  (let* ((agent (plist-get source :agent))
         (root (ashub--root (plist-get source :root)))
         (variable (pcase agent ('claude "CLAUDE_CONFIG_DIR") ('codex "CODEX_HOME")
                          ('hermes "HERMES_HOME")))
         (program (or (plist-get source :program) (symbol-name agent)))
         (environment (copy-sequence process-environment)))
    (unless variable (user-error "No terminal adapter for %s" agent))
    (unless id
      (let ((forbidden (pcase agent
                         ('claude '("--resume" "-r" "--continue" "-c" "--session-id"))
                         ('codex '("resume" "fork" "--resume" "--cd" "-C"))
                         ('hermes '("--resume" "-r" "--continue" "--in")))))
        (dolist (arg (plist-get source :args))
          (unless (stringp arg) (user-error "Source arguments must be strings"))
          (when (member (car (split-string arg "=")) forbidden)
            (user-error "New session cannot use source lifecycle argument %s" arg)))))
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
                    ('claude (when id (list "--resume" id)))
                    ('codex (if id (list "resume" id "--cd" directory) (list "--cd" directory)))
                    ('hermes (append (when id (list "--resume" id)) (list "--in" directory)))))
          environment)))

(defun ashub--terminal-command (session directory)
  "Build distinct restore argv and environment for SESSION in DIRECTORY."
  (let ((id (ashub-session-id session)))
    (unless (and (stringp id) (not (string-empty-p id)) (not (string-prefix-p "-" id)))
      (user-error "Invalid exact session ID"))
    (ashub--terminal-command-for-source (ashub-session-source session) directory id)))

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

(defun ashub--run-operation (key label operation start &optional terminal)
  "Run asynchronous START with progress for KEY, LABEL and OPERATION."
  (when (gethash key ashub--opening) (user-error "This operation is already pending"))
  (let ((token (list :label label :operation operation))
        (verb (if (eq operation 'create) "新建" "恢复")) timer cancel finished)
    (cl-labels
        ((finish (buffer error)
           (unless finished
             (setq finished t)
             (when (timerp timer) (cancel-timer timer))
             (when (eq (gethash key ashub--opening) token) (remhash key ashub--opening))
             (run-hooks 'ashub-open-state-change-hook)
             (cond
              (error (message "ashub %s失败：%s" verb error))
              ((not (buffer-live-p buffer)) (message "ashub %s失败：客户端返回了已关闭的 buffer" verb))
              (t
               (pop-to-buffer buffer)
               (message (if terminal
                            (concat verb "参数已提交；请在 agent 界面确认，Hub 未发送消息")
                          (if (eq operation 'create)
                              "客户端已确认新会话就绪；Hub 未发送消息"
                            "客户端已确认会话就绪；Hub 未发送消息"))))))))
      (puthash key token ashub--opening)
      (condition-case err
          (progn
            (run-hooks 'ashub-open-state-change-hook)
            (message "正在%s %s 会话…" verb label)
            (redisplay)
            (setq timer
                  (run-at-time ashub-open-timeout nil
                               (lambda ()
                                 (finish nil (concat verb "超时；客户端请求可能仍在执行，请检查后再重试"))
                                 (when (functionp cancel) (funcall cancel)))))
            (setq cancel (funcall start (lambda (buffer) (finish buffer nil))
                                  (lambda (error) (finish nil error)))))
        (quit (finish nil (concat verb "已取消；客户端请求可能仍在执行"))
              (when (functionp cancel) (funcall cancel)) (signal 'quit nil))
        (error (finish nil (error-message-string err)))))))

(defun ashub--create-terminal (source directory on-ready)
  "Start a fresh CLI through the same ghostel backend, never a resume argv."
  (when ashub-terminal-open-function
    (user-error "Custom terminal backend needs a source :create-function"))
  (pcase-let* ((`(,program ,args ,environment) (ashub--terminal-command-for-source source directory))
               (process-environment environment)
               (exec-path (append (parse-colon-path (getenv "PATH")) exec-path))
               (executable (executable-find program)))
    (unless executable (user-error "Missing %s executable; install/configure it yourself" program))
    (require 'ghostel nil t)
    (unless (fboundp 'ghostel-exec) (user-error "Missing ghostel-exec; configure ghostel first"))
    (let ((buffer (generate-new-buffer (format "*ashub new %s %s*" (plist-get source :agent)
                                               (file-name-nondirectory (directory-file-name directory))))))
      (with-current-buffer buffer
        (setq default-directory directory)
        (let ((ghostel-module-auto-install nil))
          (unless (process-live-p
                   (ghostel-exec buffer executable args
                                 `((kind . ashub-new) (agent . ,(plist-get source :agent))
                                   (command . (,executable . ,args)))))
            (user-error "Ghostel did not start a live process"))))
      (funcall on-ready buffer))))

(defun ashub--creation-source (agent)
  "Choose AGENT's sole source or its explicitly configured default source."
  (let* ((sources (seq-filter (lambda (source) (eq (plist-get source :agent) agent))
                              (ashub-configured-sources)))
         (default (seq-find (lambda (source) (eq (plist-get source :agent) agent))
                            (ashub-default-sources))))
    (or (and (= (length sources) 1) (car sources))
        (seq-find (lambda (source) (equal (ashub-source-key source) (ashub-source-key default))) sources)
        (user-error "No unambiguous creation source for %s; configure its default or use its own client" agent))))

(defun ashub-create-session (agent directory)
  "Create AGENT in selected local DIRECTORY, without a history picker or prompt."
  (unless (memq agent '(claude codex pi dsh hermes)) (user-error "Unknown agent: %s" agent))
  (unless (ashub--local-directory-p directory) (user-error "请选择现有的本地绝对项目目录"))
  (setq directory (file-name-as-directory (file-truename directory)))
  (let* ((source (ashub--creation-source agent))
         (custom (plist-get source :create-function))
         (terminal (and (memq agent '(claude codex hermes)) (not custom)))
         (key (list 'new (ashub-source-key source) directory)))
    (when (and (plist-get source :open-function) (not custom))
      (user-error "This custom client source needs an explicit :create-function"))
    (ashub--run-operation
     key (format "%s %s" agent (abbreviate-file-name directory)) 'create
     (lambda (ready error)
       (cond
        (custom (funcall custom source directory ready error))
        (terminal (ashub--create-terminal source directory ready))
        ((eq agent 'pi)
         (require 'emacs-pi nil t)
         (unless (fboundp 'emacs-pi-create-session) (user-error "Update emacs-pi: emacs-pi-create-session missing"))
         (emacs-pi-create-session directory :session-directory (ashub--root (plist-get source :root))
                                  :display 'none :on-ready ready :on-error error))
        ((eq agent 'dsh)
         (require 'emacs-dsh nil t)
         (unless (fboundp 'emacs-dsh-create-session) (user-error "Update emacs-dsh: emacs-dsh-create-session missing"))
         (emacs-dsh-create-session directory :display 'none :on-ready ready :on-error error))))
     terminal)))

(defun ashub-open-session (session)
  "Restore selected SESSION with immediate feedback, without sending a message."
  (when (eq (ashub-session-archived session) t)
    (user-error "Archived session: unarchive in its own client, then refresh; Hub will not unarchive"))
  (let* ((key (ashub-session-key session))
         (source (ashub-session-source session))
         (agent (ashub-session-agent session)))
    (when (gethash key ashub--opening)
      (user-error "This session is already opening; wait for readiness or timeout"))
    (unless (or (eq agent 'dsh) (file-directory-p (ashub--root (plist-get source :root))))
      (user-error "Storage source unavailable; refusing to create or use a substitute profile"))
    (let ((directory (ashub--restore-directory session))
          (terminal (and (memq agent '(claude codex hermes)) (not (plist-get source :open-function)))))
      (ashub--run-operation
       key (format "%s %s" agent (substring (ashub-session-id session) 0 (min 12 (length (ashub-session-id session)))))
       'restore
       (lambda (ready error)
         (cond
          (terminal (ashub--open-terminal session directory ready))
          ((plist-get source :open-function)
           (funcall (plist-get source :open-function) session directory ready error))
          ((eq agent 'pi)
           (require 'emacs-pi nil t)
           (unless (fboundp 'emacs-pi-open-session) (user-error "Load API-capable emacs-pi (emacs-pi-open-session missing)"))
           (emacs-pi-open-session (ashub-session-path session) :directory directory
                                  :session-directory (ashub--root (plist-get source :root))
                                  :display 'none :on-ready ready :on-error error))
          ((eq agent 'dsh)
           (require 'emacs-dsh nil t)
           (unless (fboundp 'emacs-dsh-open-session) (user-error "Load API-capable emacs-dsh (emacs-dsh-open-session missing)"))
           (ashub--dsh-source-check session)
           (emacs-dsh-open-session
            (ashub-session-id session) :directory directory :display 'none
            :on-ready (lambda (buffer)
                        (condition-case err
                            (progn (ashub--dsh-source-check session) (funcall ready buffer))
                          (error (funcall error (error-message-string err)))))
            :on-error error))
          (t (user-error "No restore adapter for %s" agent))))
       terminal))))

(provide 'ashub-open)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; ashub-open.el ends here
