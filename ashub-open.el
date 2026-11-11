;;; ashub-open.el --- Exact-session restore dispatch -*- lexical-binding: t; -*-

;;; Commentary:
;; Explicit user actions only.  No prompt sending, shell command strings,
;; auto-installation, profile fallback, unarchiving or disk mapping cache.

;;; Code:
(require 'ashub-core)
(require 'ashub-tmux)
(declare-function ghostel-exec "ghostel" (buffer program &optional args identity))
(declare-function emacs-pi-open-session "emacs-pi")
(declare-function emacs-pi-fork-session-file "emacs-pi")
(declare-function emacs-pi-session-session-file "emacs-pi-session" (session))
(defvar emacs-pi--session)
(declare-function emacs-dsh-open-session "emacs-dsh")
(declare-function emacs-pi-create-session "emacs-pi")
(declare-function emacs-dsh-create-session "emacs-dsh")
(declare-function emacs-dsh--source-identity "emacs-dsh" ())
(defvar ghostel-module-auto-install)
(defvar ghostel-query-before-killing)
(defvar ghostel-kill-buffer-on-exit)
(defvar-local ashub--terminal-state nil)
(defvar-local ashub--terminal-process nil)
(defvar-local ashub--terminal-nonce nil)

(defcustom ashub-open-timeout 60 "Seconds before a creation or restore request times out."
  :type 'number :group 'ashub)
(defvar ashub--instances (make-hash-table :test #'equal)
  "Hub-owned terminal buffers/processes, indexed by full source-qualified key.")
(defvar-local ashub--new-terminal-agent nil)
(defvar-local ashub--new-terminal-source nil)
(defvar-local ashub--new-terminal-process nil)
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

(defun ashub--pi-read-header (path)
  "Read a bounded JSONL session header from PATH, or signal an error."
  (with-temp-buffer
    (insert-file-contents path nil 0 65536)
    (goto-char (point-min))
    (unless (search-forward "\n" nil t)
      (error "Pi session has no complete header line"))
    (json-parse-string (buffer-substring-no-properties
                        (point-min) (1- (point)))
                       :object-type 'hash-table)))

(defun ashub--pi-relocation-fork-needed-p (session directory)
  "Whether SESSION must be forked because its relocated cwd is missing."
  (let* ((path (ashub-session-path session))
         (header (and (stringp path) (file-regular-p path)
                      (ashub--pi-read-header path)))
         (cwd (and header (gethash "cwd" header)))
         (mapped (and (stringp cwd) (ashub--relocate-cwd cwd))))
    (and (stringp cwd) (file-name-absolute-p cwd) (not (file-remote-p cwd))
         (not (file-directory-p cwd))
         (stringp mapped) (not (equal (expand-file-name mapped) (expand-file-name cwd)))
         (ashub--local-directory-p mapped)
         (equal (file-name-as-directory (file-truename mapped)) directory))))

(defun ashub--pi-jsonl-records (path)
  "Parse all non-header JSONL records in PATH, or return nil on malformed input."
  (with-temp-buffer
    (insert-file-contents path)
    (goto-char (point-min))
    (unless (search-forward "\n" nil t) (error "Missing JSONL header"))
    (let (records)
      (while (< (point) (point-max))
        (let ((start (point)))
          (forward-line 1)
          (let ((line (string-trim (buffer-substring-no-properties start (point)))))
            (unless (string-empty-p line)
              (push (json-parse-string line :object-type 'alist :array-type 'list
                                       :null-object :null :false-object :false)
                    records)))))
      (nreverse records))))

(defun ashub--pi-history-preserved-p (source fork)
  "Whether every source record appears unchanged and in order at FORK's start."
  (let* ((source-records (ashub--pi-jsonl-records source))
         (fork-records (ashub--pi-jsonl-records fork))
         (source-count (length source-records)))
    (and (<= source-count (length fork-records))
         (equal source-records (cl-subseq fork-records 0 source-count)))))

(defun ashub--pi-fork-matches-session-p (source fork directory)
  "Verify FORK is a live fork of SOURCE in DIRECTORY with all records intact."
  (let* ((source-header (ashub--pi-read-header source))
         (fork-header (ashub--pi-read-header fork))
         (source-id (gethash "id" source-header))
         (fork-id (gethash "id" fork-header))
         (fork-cwd (gethash "cwd" fork-header)))
    (and (stringp source-id) (stringp fork-id) (not (equal source-id fork-id))
         (equal (gethash "type" source-header) "session")
         (equal (gethash "type" fork-header) "session")
         (equal (gethash "parentSession" fork-header) (file-truename source))
         (stringp fork-cwd)
         (equal (file-name-as-directory (file-truename fork-cwd)) directory)
         (ashub--pi-history-preserved-p source fork))))

(defun ashub--pi-detach-fork-parent (path)
  "Atomically remove the parentSession reference from fork file PATH."
  (let* ((header (ashub--pi-read-header path))
         (temporary-file-directory (file-name-directory path))
         (temporary (make-temp-file (expand-file-name ".ashub-fork-" temporary-file-directory)))
         (mode (file-modes path)))
    (unwind-protect
        (progn
          (remhash "parentSession" header)
          (with-temp-buffer
            (insert-file-contents path)
            (goto-char (point-min))
            (unless (search-forward "\n" nil t) (error "Missing fork header"))
            (delete-region (point-min) (point))
            (goto-char (point-min))
            (insert (json-serialize header) "\n")
            (write-region (point-min) (point-max) temporary nil 'silent))
          (set-file-modes temporary mode)
          (rename-file temporary path t)
          (when (gethash "parentSession" (ashub--pi-read-header path))
            (error "Could not clear fork parent reference")))
      (when (file-exists-p temporary) (delete-file temporary)))))

(defun ashub--pi-relocation-fork (session directory on-ready on-error)
  "Fork a relocated Pi SESSION and delete its source only after verification."
  (let ((source (ashub-session-path session))
        (storage (ashub--root (plist-get (ashub-session-source session) :root))))
    (if (not (and (fboundp 'emacs-pi-fork-session-file)
                  (fboundp 'emacs-pi-session-session-file)))
        (funcall on-error "Update emacs-pi: verified session-file fork API is required")
      (emacs-pi-fork-session-file
     source :directory directory :session-directory storage :display 'none
     :on-ready
     (lambda (buffer)
       (condition-case err
           (let ((fork (with-current-buffer buffer
                         (emacs-pi-session-session-file emacs-pi--session))))
             (unless (and (stringp fork) (file-regular-p fork)
                          (not (file-equal-p source fork))
                          (ashub--pi-fork-matches-session-p source fork directory))
               (error "Fork did not preserve the complete original history"))
             (ashub--pi-detach-fork-parent fork)
             (unless (and (ashub--pi-history-preserved-p source fork)
                          (not (gethash "parentSession" (ashub--pi-read-header fork))))
               (error "Fork history or detached header did not verify"))
             (delete-file source)
             (funcall on-ready buffer))
         (error
          (funcall on-error
                   (format "Pi relocation fork verification failed; original retained: %s"
                           (error-message-string err))))))
       :on-error on-error))))

(defun ashub--terminal-command-for-source (source directory &optional id)
  "Build source-bound CLI argv; ID selects restore, nil selects a fresh session."
  (let* ((agent (plist-get source :agent))
         (root (ashub--root (plist-get source :root)))
         (variable (pcase agent ('claude "CLAUDE_CONFIG_DIR") ('codex "CODEX_HOME")
                          ('hermes "HERMES_HOME")))
         (program (or (plist-get source :program) (symbol-name agent)))
         (environment (copy-sequence process-environment)))
    (unless variable (user-error "No terminal adapter for %s" agent))
    (let ((forbidden (pcase agent
                       ('claude '("--resume" "-r" "--continue" "-c" "--session-id" "--fork-session"))
                       ('codex '("resume" "fork" "--resume" "--cd" "-C"))
                       ('hermes '("--resume" "-r" "--continue" "-c" "--in" "--profile" "-p")))))
      (dolist (arg (plist-get source :args))
        (unless (stringp arg) (user-error "Source arguments must be strings"))
        (when (or (member (car (split-string arg "=")) forbidden)
                  (and (eq agent 'hermes) (string-prefix-p "-p" arg) (not (string-prefix-p "--" arg))))
          (user-error "Source lifecycle arguments are managed by ashub: %s" arg))))
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

(defun ashub--terminal-renderer-check ()
  "Require the existing renderer without permitting module installation."
  (let ((ghostel-module-auto-install nil)) (require 'ghostel nil t))
  (unless (fboundp 'ghostel-exec)
    (user-error "Missing ghostel-exec; configure ghostel before starting a persistent terminal")))

(defun ashub--terminal-launch (source directory &optional id)
  "Launch SOURCE in DIRECTORY with literal argv; ID is exact history."
  (ashub--terminal-renderer-check)
  (pcase-let* ((`(,program ,args ,environment) (ashub--terminal-command-for-source source directory id))
               (process-environment environment)
               (exec-path (append (parse-colon-path (getenv "PATH")) exec-path))
               (executable (executable-find program)))
    (unless executable (user-error "Missing %s executable; install/configure it yourself" program))
    (ashub-tmux-ensure source directory executable args environment id)))

(defun ashub-terminal--detach ()
  "Release this buffer's controller only; never finish its agent."
  (when (and ashub--terminal-state ashub--terminal-nonce)
    (let ((state ashub--terminal-state) (nonce ashub--terminal-nonce))
      (setq ashub--terminal-nonce nil)
      (condition-case nil (ashub-tmux-controller "release" state nonce)
        (error (message "ashub: UI detached; backend retained, controller release not confirmed")))))
  (run-hooks 'ashub-open-state-change-hook))

(defun ashub-terminal-finish ()
  "Finish this owned instance, retaining history; kill the UI only on success."
  (interactive)
  (unless ashub--terminal-state (user-error "This buffer has no owned terminal instance"))
  (when (or (not (called-interactively-p 'interactive))
            (yes-or-no-p "End this agent and its owned process group? History will be kept. "))
    (let* ((buffer (current-buffer)) (state ashub--terminal-state)
           (result (ashub-tmux-finish (plist-get state :runtimeId) (plist-get state :generation))))
      (unless (member (plist-get result :status) '("finished" "exited" "failed" "absent"))
        (user-error "Finish not confirmed; keeping terminal UI"))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(define-minor-mode ashub-terminal-session-mode
  "Persistent terminal UI: ordinary buffer kill detaches; C-c C-q finishes."
  :lighter " Hub↔tmux"
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-q") #'ashub-terminal-finish)
            map))

(defun ashub-terminal--runtime-updated ()
  "Sync cached native IDs without changing a buffer's ownership generation."
  (let ((states (ashub-tmux-current-snapshot)))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when ashub--terminal-state
          (when-let* ((fresh (seq-find
                             (lambda (state)
                               (and (equal (plist-get state :runtimeId) (plist-get ashub--terminal-state :runtimeId))
                                    (equal (plist-get state :generation) (plist-get ashub--terminal-state :generation))))
                             states)))
            (setq ashub--terminal-state fresh)))))))

(add-hook 'ashub-tmux-snapshot-change-hook #'ashub-terminal--runtime-updated)

(defun ashub--attach-terminal (state source on-ready &optional key)
  "Attach one writable Ghostel UI to authenticated STATE for SOURCE."
  (ashub--terminal-renderer-check)
  (let* ((id (plist-get state :runtimeId)) (generation (plist-get state :generation))
         (old (seq-find (lambda (buffer)
                          (with-current-buffer buffer
                            (and (equal id (plist-get ashub--terminal-state :runtimeId))
                                 (equal generation (plist-get ashub--terminal-state :generation)))))
                        (buffer-list))))
    (if (and old (with-current-buffer old (process-live-p ashub--terminal-process)))
        (progn
          (with-current-buffer old (setq ashub--terminal-state state))
          (when key (puthash key (list :buffer old :process (buffer-local-value 'ashub--terminal-process old))
                            ashub--instances))
          (funcall on-ready old))
      (when old (kill-buffer old))
      (let* ((nonce (substring (secure-hash 'sha256 (format "%s:%s:%s" (emacs-pid) (current-time) (random))) 0 32))
             (buffer (generate-new-buffer (format "*ashub %s %s*" (plist-get source :agent) (substring id 0 12))))
             (process-environment (append '("TMUX=") process-environment))
             process committed)
        (unwind-protect
            (progn
              (ashub-tmux-controller "claim" state nonce)
              (pcase-let ((`(,program . ,args) (ashub-tmux-attach-command id generation)))
                (with-current-buffer buffer
                  (setq default-directory
                        (if (file-directory-p (plist-get state :directory))
                            (file-name-as-directory (plist-get state :directory))
                          (file-name-directory ashub-tmux--helper-file)))
                  (let ((ghostel-module-auto-install nil))
                    ;; Do not store a raw command in bookmark/desktop identity:
                    ;; replaying it would bypass the controller lease.
                    (setq process (ghostel-exec buffer program args
                                                `((kind . ashub-runtime) (runtime . ,id)
                                                  (generation . ,generation) (agent . ,(plist-get source :agent))))))
                  (unless (process-live-p process) (user-error "Ghostel did not attach a live client"))
                  (setq-local ashub--terminal-state state ashub--terminal-nonce nonce
                              ashub--terminal-process process
                              ghostel-query-before-killing nil ghostel-kill-buffer-on-exit nil)
                  (when (not (plist-get state :sessionId))
                    (setq-local ashub--new-terminal-agent (plist-get source :agent)
                                ashub--new-terminal-source source ashub--new-terminal-process process))
                  (ashub-terminal-session-mode 1)
                  (add-hook 'kill-buffer-hook #'ashub-terminal--detach t t)))
              (let ((deadline (+ (float-time) 5)) attached)
                (while (and (process-live-p process) (not attached) (< (float-time) deadline))
                  (let ((current (ashub-tmux-inspect id)))
                    (unless (and (equal id (plist-get current :runtimeId))
                                 (equal generation (plist-get current :generation))
                                 (member (plist-get current :status) '("running" "stopping")))
                      (user-error "Terminal ownership changed while attaching; backend retained"))
                    (with-current-buffer buffer (setq ashub--terminal-state current))
                    (setq attached (equal (plist-get current :attachedClients) 1)))
                  (unless attached (accept-process-output process 0.04)))
                (unless attached
                  (user-error "Attach not confirmed; backend retained (check Ghostel/TERM)")))
              (puthash (or key (list 'runtime id)) (list :buffer buffer :process process) ashub--instances)
              (setq committed t)
              (funcall on-ready buffer))
          (unless committed
            (when (buffer-live-p buffer) (kill-buffer buffer))
            (ignore-errors (ashub-tmux-controller "release" state nonce))))))))

(defun ashub-terminal-attach-existing ()
  "Select a durable running instance, including one not indexed by history yet."
  (interactive)
  (let* ((states (seq-filter (lambda (state) (member (plist-get state :status) '("running" "stopping" "unknown")))
                             (ashub-tmux-list)))
         (choices (mapcar (lambda (state)
                            (cons (format "%s %s %s [%s]"
                                          (plist-get (plist-get state :source) :agent)
                                          (plist-get state :runtimeId)
                                          (plist-get state :directory) (plist-get state :status)) state)) states)))
    (unless choices (user-error "No retained terminal instances"))
    (let* ((state (cdr (assoc (completing-read "Attach instance: " choices nil t) choices)))
           (identity (plist-get state :source))
           (source (list :agent (intern (plist-get identity :agent))
                         :root (plist-get identity :root) :profile (plist-get identity :profile))))
      (ashub--attach-terminal state source #'pop-to-buffer))))

(defun ashub--open-terminal (session directory on-ready &optional runtime)
  "Attach SESSION's owner first; only proven absence permits exact recovery."
  (let* ((key (ashub-session-key session)) (old (gethash key ashub--instances))
         (buffer (plist-get old :buffer)) (process (plist-get old :process))
         (source (ashub-session-source session)))
    (cond
     ((and ashub-terminal-open-function (buffer-live-p buffer) (process-live-p process)) (funcall on-ready buffer))
     (ashub-terminal-open-function
      (pcase-let* ((`(,program ,args ,environment) (ashub--terminal-command session directory))
                   (process-environment environment)
                   (exec-path (append (parse-colon-path (getenv "PATH")) exec-path))
                   (executable (executable-find program)))
        (unless executable (user-error "Missing %s executable; install/configure it yourself" program))
        (funcall ashub-terminal-open-function session executable args directory environment on-ready)))
     (t
      (let ((state (or runtime (ashub-tmux-find source (ashub-session-id session)
                                               (plist-get (ashub-session-metadata session) :runtime-id)))))
        (when (and (not state) (plist-get (ashub-session-metadata session) :runtime-id))
          (user-error "Unindexed runtime ended; refresh instead of guessing a history ID"))
        (ashub--attach-terminal (or state (ashub--terminal-launch source directory (ashub-session-id session)))
                                source on-ready key))))))

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
               (delete-other-windows)
               (message (if terminal
                            (concat verb "已连接终端实例；请在 agent 界面确认历史身份，Hub 未发送消息")
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
  "Create a fresh independently owned CLI, then attach its leased UI."
  (when ashub-terminal-open-function
    (user-error "Custom terminal backend needs a source :create-function"))
  (ashub--attach-terminal (ashub--terminal-launch source directory) source on-ready))

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
  "Attach native Pi before disk/cwd/fork checks; restore other clients normally."
  (if (or (not (eq (ashub-session-agent session) 'pi))
          (plist-get (ashub-session-source session) :open-function))
      (ashub--open-session-history session)
    (let* ((source (ashub-session-source session))
           (key (ashub-session-key session)))
      (when (gethash key ashub--opening) (user-error "This session is already opening"))
      (ashub--run-operation
       key (format "pi %s" (ashub-session-id session)) 'restore
       (lambda (ready error)
         (require 'emacs-pi nil t)
         (unless (fboundp 'emacs-pi-open-session) (user-error "Update emacs-pi: owner-first public API required"))
         (emacs-pi-open-session
          (ashub-session-path session) :expected-id (ashub-session-id session)
          :session-directory (ashub--root (plist-get source :root)) :display 'none :on-ready ready :on-error error
          :on-missing
          (lambda ()
            (condition-case err
                (progn
                  (when (eq (ashub-session-archived session) t) (user-error "Archived session; Hub will not unarchive"))
                  (unless (file-directory-p (ashub--root (plist-get source :root)))
                    (user-error "Storage source unavailable; no substitute profile"))
                  (let ((directory (ashub--restore-directory session)))
                    (if (ashub--pi-relocation-fork-needed-p session directory)
                        (ashub--pi-relocation-fork session directory ready error)
                      (emacs-pi-open-session (ashub-session-path session) :directory directory
                                            :expected-id (ashub-session-id session)
                                            :session-directory (ashub--root (plist-get source :root))
                                            :display 'none :on-ready ready :on-error error))))
              (error (funcall error (error-message-string err)))))))))))

(defun ashub--open-session-history (session)
  "Restore selected SESSION with immediate feedback, without sending a message."
  (let* ((key (ashub-session-key session))
         (source (ashub-session-source session))
         (agent (ashub-session-agent session))
         (terminal (and (memq agent '(claude codex hermes)) (not (plist-get source :open-function))))
         (runtime (and terminal (not ashub-terminal-open-function)
                       (ashub-tmux-find source (ashub-session-id session)
                                        (plist-get (ashub-session-metadata session) :runtime-id)))))
    (when (and (not runtime) (eq (ashub-session-archived session) t))
      (user-error "Archived session: unarchive in its own client, then refresh; Hub will not unarchive"))
    (when (and (not runtime) (plist-get (ashub-session-metadata session) :runtime-id))
      (user-error "Unindexed runtime ended; refresh instead of guessing a history ID"))
    (when (gethash key ashub--opening)
      (user-error "This session is already opening; wait for readiness or timeout"))
    (unless (or runtime (eq agent 'dsh) (file-directory-p (ashub--root (plist-get source :root))))
      (user-error "Storage source unavailable; refusing to create or use a substitute profile"))
    (let ((directory (if runtime (plist-get runtime :directory) (ashub--restore-directory session))))
      (ashub--run-operation
       key (format "%s %s" agent (substring (ashub-session-id session) 0 (min 12 (length (ashub-session-id session)))))
       'restore
       (lambda (ready error)
         (cond
          (terminal (ashub--open-terminal session directory ready runtime))
          ((plist-get source :open-function)
           (funcall (plist-get source :open-function) session directory ready error))
          ((eq agent 'pi)
           (require 'emacs-pi nil t)
           (unless (fboundp 'emacs-pi-open-session) (user-error "Load API-capable emacs-pi (emacs-pi-open-session missing)"))
           (if (ashub--pi-relocation-fork-needed-p session directory)
               (ashub--pi-relocation-fork session directory ready error)
             (emacs-pi-open-session (ashub-session-path session) :directory directory
                                    :session-directory (ashub--root (plist-get source :root))
                                    :display 'none :on-ready ready :on-error error)))
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
