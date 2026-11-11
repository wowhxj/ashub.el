;;; ashub-tmux.el --- Persistent terminal instance ownership -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Package-Requires: ((emacs "29.1"))
;; Version: 0.1.0
;; Keywords: tools, processes

;;; Commentary:
;; A bundled Python stdlib owner runs inside a dedicated private tmux server.
;; Emacs owns only an attach client, not the agent.  These entry points never
;; send prompts and never signal a process identified only by a stored PID.

;;; Code:
(require 'ashub-core)
(require 'json)

(defcustom ashub-tmux-program "tmux"
  "Tmux 3.2+ executable for the built-in persistent terminal backend."
  :type 'string :group 'ashub)

(defcustom ashub-terminal-runtime-directory
  (expand-file-name ".ashub-runtime" "~")
  "Short, private local directory for terminal ownership and IPC.
Its parent must exist.  An existing directory must belong to you and have
mode 0700; symlink runtime directories are rejected.  No other tmux server
is used.  The initial implementation supports macOS/POSIX, not Windows."
  :type 'directory :group 'ashub)

(defcustom ashub-tmux-operation-timeout 25
  "Seconds before giving up on a terminal management operation.
A timeout is an unknown outcome, never permission to start another writer."
  :type 'number :group 'ashub)

(defconst ashub-tmux--helper-file
  (expand-file-name "ashub-terminal.py"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Bundled stdlib-only terminal owner resource.")

(defun ashub-tmux--tools ()
  "Return (PYTHON TMUX), checking prerequisites without installing anything."
  (unless (memq system-type '(darwin gnu/linux berkeley-unix))
    (user-error "Persistent terminal ownership currently requires POSIX"))
  (when (file-remote-p ashub-terminal-runtime-directory)
    (user-error "Terminal runtime directory must be local"))
  (unless (file-readable-p ashub-tmux--helper-file)
    (user-error "Missing bundled ashub-terminal.py; reinstall the complete package"))
  (list (or (executable-find ashub-python-program)
            (user-error "Missing Python 3.9+: configure ashub-python-program"))
        (or (executable-find ashub-tmux-program)
            (user-error "Missing tmux 3.2+; install/configure it yourself"))))

(defun ashub-tmux--call (operation request)
  "Send REQUEST to the owner manager's OPERATION, returning decoded JSON.
Only the local manager is terminated on timeout or quit.  Its independently
owned tmux pane is retained; a caller must inspect before any retry."
  (pcase-let* ((`(,python ,tmux) (ashub-tmux--tools))
               (output (generate-new-buffer " *ashub runtime*"))
               (errors (generate-new-buffer " *ashub runtime errors*"))
               (default-directory (file-name-directory ashub-tmux--helper-file))
               (deadline (+ (float-time) ashub-tmux-operation-timeout))
               (process nil))
    (unwind-protect
        (progn
          (setq process
                (make-process
                 :name "ashub-runtime-manager" :buffer output :stderr errors
                 :connection-type 'pipe :coding 'utf-8-unix :noquery t
                 :command (list python "-I" "-B" ashub-tmux--helper-file operation
                                "--runtime-root" (expand-file-name ashub-terminal-runtime-directory)
                                "--tmux" tmux)))
          (process-send-string process (json-serialize request :null-object nil :false-object :json-false))
          (process-send-eof process)
          (while (and (process-live-p process) (< (float-time) deadline))
            (accept-process-output process 0.04))
          (when (process-live-p process)
            (user-error "Terminal operation timed out; outcome unknown, inspect before retrying"))
          (let ((reply (condition-case nil
                           (with-current-buffer output
                             (goto-char (point-min))
                             (json-parse-buffer :object-type 'plist :array-type 'list
                                                :null-object nil :false-object :json-false))
                         (error (user-error "Terminal helper failed; check Python, tmux and bundled resources")))))
            (when (and (listp reply) (keywordp (car reply)) (plist-get reply :error))
              (user-error "%s" (plist-get reply :error)))
            (unless (zerop (process-exit-status process))
              (user-error "Terminal manager failed; outcome unknown"))
            reply))
      (when (process-live-p process) (delete-process process))
      (kill-buffer output)
      (kill-buffer errors))))

(defun ashub-tmux--source (source)
  "Return the non-secret persistent identity portion of SOURCE."
  (list :agent (symbol-name (plist-get source :agent))
        :root (ashub--root (plist-get source :root))
        :profile (plist-get source :profile)))

(defun ashub-tmux--environment (environment)
  "Convert Emacs ENVIRONMENT to a JSON string map, honoring first binding."
  (let ((result (make-hash-table :test #'equal)))
    (dolist (entry environment)
      (when (and (stringp entry) (string-match "\\`\\([^=]+\\)=" entry))
        (let ((name (match-string 1 entry)) (value (substring entry (match-end 0))))
          (unless (gethash name result)
            (puthash name value result)))))
    result))

(defun ashub-tmux-ensure (source directory program args environment &optional session-id)
  "Ensure one SOURCE-owned terminal and return its public runtime plist.
PROGRAM, ARGS and ENVIRONMENT are structured, never a shell command string.
SESSION-ID selects exact history; nil creates a new, initially unindexed
terminal.  An unknown existing owner blocks duplicate history writers.
Only explicit source options enter the configuration fingerprint; changing
unrelated inherited Emacs environment does not invalidate a reconnect."
  (let ((state (ashub-tmux--call
                "ensure"
                (list :source (ashub-tmux--source source) :directory directory
                      :program program :args (vconcat args)
                      :environment (ashub-tmux--environment environment)
                      :sourceArgs (vconcat (plist-get source :args))
                      :sourceEnvironment (vconcat (plist-get source :environment))
                      :sessionId session-id))))
    (unless (member (plist-get state :status) '("running" "stopping"))
      (user-error "Terminal not ready (%s); inspect before retrying" (plist-get state :status)))
    state))

(defun ashub-tmux-list (&optional source)
  "Read public terminal runtime plists, optionally restricted to SOURCE.
Never starts tmux or creates a runtime directory.  Unknown owners remain
unknown rather than being advertised as idle, absent or safely restorable."
  (ashub-tmux--call "list" (if source (list :source (ashub-tmux--source source))
                           (make-hash-table))))

(defun ashub-tmux-inspect (runtime-id)
  "Read RUNTIME-ID's authenticated public state without starting anything."
  (ashub-tmux--call "inspect" (list :runtimeId runtime-id)))

(defun ashub-tmux-finish (runtime-id generation)
  "Explicitly finish RUNTIME-ID at GENERATION, retaining all agent history.
Returns only after verified completion or absence.  On failure/unknown the
caller must retain its UI.  This never uses recorded PIDs as kill authority
and never escalates to SIGKILL."
  (ashub-tmux--call "finish" (list :runtimeId runtime-id :generation generation)))

(defun ashub-tmux-find (source session-id &optional runtime-id)
  "Find SOURCE's nonterminal owner by exact SESSION-ID or RUNTIME-ID.
Unknown ownership is returned for explicit instance lookup, never absence.
Unknown/unindexed owners block history recovery rather than a second writer."
  (let* ((states (seq-remove (lambda (state)
                               (member (plist-get state :status) '("finished" "exited" "failed")))
                             (ashub-tmux-list source)))
         (matches (seq-filter (lambda (state)
                                (if runtime-id (equal runtime-id (plist-get state :runtimeId))
                                  (and session-id (equal session-id (plist-get state :sessionId)))))
                              states)))
    (when (and session-id (not runtime-id)
               (seq-some (lambda (state) (equal (plist-get state :status) "unknown")) states))
      (user-error "Terminal ownership is unknown for this storage home; refusing history restore"))
    (when (> (length matches) 1) (user-error "Multiple owners claim this history; refusing to guess"))
    (when (and (not matches) session-id (not runtime-id)
               (seq-some (lambda (state)
                           (or (plist-get state :identityOverflow)
                               (member session-id (plist-get state :previousSessionIds)))) states))
      (user-error "History is reserved by an earlier conversation of a live instance; attach its current instance or finish it first"))
    (when (and (not matches) session-id (not runtime-id)
               (seq-some (lambda (state) (not (plist-get state :sessionId))) states))
      (user-error "Unindexed active terminal: use M-x ashub-terminal-attach-existing before restoring history"))
    (car matches)))

(defun ashub-tmux-controller (operation state nonce)
  "Claim/release STATE's writable controller lease using buffer NONCE.
OPERATION is claim or release.  PID is a liveness guard, never kill authority."
  (unless (member operation '("claim" "release")) (error "Invalid controller operation"))
  (ashub-tmux--call operation (list :runtimeId (plist-get state :runtimeId)
                                   :generation (plist-get state :generation)
                                   :clientPid (emacs-pid) :clientNonce nonce)))

(defun ashub-tmux-attach-command (runtime-id generation)
  "Return literal tmux attach argv for the authenticated GENERATION.
This is a transport primitive; the caller must serialize controller leases
before launching a writable terminal client."
  (let ((state (ashub-tmux-inspect runtime-id)))
    (unless (and (equal generation (plist-get state :generation))
                 (member (plist-get state :status) '("running" "stopping")))
      (user-error "Terminal owner unavailable or generation changed; refresh before attaching"))
    (list (cadr (ashub-tmux--tools)) "-S"
          (expand-file-name "tmux.sock" ashub-terminal-runtime-directory)
          "attach-session" "-E" "-t" (concat "=" (plist-get state :name)))))

(defcustom ashub-tmux-snapshot-max-age 10
  "Maximum seconds an inventory can authorize background summary work."
  :type 'number :group 'ashub)
(defvar ashub-tmux-snapshot nil "Last successful read-only runtime inventory.")
(defvar ashub-tmux-snapshot-status 'unknown "Inventory state: unknown, loading or ready.")
(defvar ashub-tmux-snapshot-time nil "Time of the last successful inventory.")
(defvar ashub-tmux-snapshot-root nil "Registry identity of the cached inventory.")
(defvar ashub-tmux-snapshot-error nil "Last inventory error, without credentials.")
(defvar ashub-tmux-snapshot-change-hook nil "Hook after an inventory result changes.")
(defvar ashub-tmux--snapshot-cancel nil)
(defvar ashub-tmux--snapshot-generation 0)
(defvar ashub-tmux--snapshot-retry-at 0)

(defun ashub-tmux--list-async (success failure)
  "Read inventory asynchronously; call SUCCESS or FAILURE once, returning cancel.
Cancel/timeout affect only this read-only manager, never any backend."
  (pcase-let* ((`(,python ,tmux) (ashub-tmux--tools))
               (default-directory (file-name-directory ashub-tmux--helper-file))
               (output (generate-new-buffer " *ashub runtime inventory*"))
               (errors (generate-new-buffer " *ashub runtime inventory errors*"))
               (process nil) (timer nil) (done nil))
    (cl-labels
        ((finish (value error &optional cancelled)
           (unless done
             (setq done t)
             (when (timerp timer) (cancel-timer timer))
             (when (process-live-p process) (delete-process process))
             (kill-buffer output) (kill-buffer errors)
             (unless cancelled (if error (funcall failure error) (funcall success value)))))
         (receive (_process _event)
           (when (and (not done) (not (process-live-p process)))
             (condition-case err
                 (let ((value (with-current-buffer output
                                (goto-char (point-min))
                                (json-parse-buffer :object-type 'plist :array-type 'list
                                                   :null-object nil :false-object :json-false))))
                   (when (and (keywordp (car-safe value)) (plist-get value :error))
                     (error "%s" (plist-get value :error)))
                   (unless (and (zerop (process-exit-status process)) (listp value))
                     (error "Invalid terminal runtime inventory"))
                   (finish value nil))
               (error (finish nil (error-message-string err)))))))
      (condition-case err
          (progn
            (setq process (make-process
                           :name "ashub-runtime-inventory" :buffer output :stderr errors
                           :connection-type 'pipe :coding 'utf-8-unix :noquery t :sentinel #'receive
                           :command (list python "-I" "-B" ashub-tmux--helper-file "list"
                                          "--runtime-root" (expand-file-name ashub-terminal-runtime-directory)
                                          "--tmux" tmux)))
            (setq timer (run-at-time ashub-tmux-operation-timeout nil
                                     (lambda () (finish nil "Runtime inventory timed out; state unknown"))))
            (process-send-string process "{}") (process-send-eof process))
        (error (finish nil (error-message-string err))))
      (lambda () (finish nil nil t)))))

(defun ashub-tmux-refresh-snapshot (&optional force)
  "Refresh runtime inventory without starting an owner or resuming a session.
FORCE cancels an older query; callbacks from older generations are ignored."
  (unless (and (not force)
               (equal ashub-tmux-snapshot-root (expand-file-name ashub-terminal-runtime-directory))
               (or (eq ashub-tmux-snapshot-status 'loading)
                   (< (float-time) ashub-tmux--snapshot-retry-at)))
    (cl-incf ashub-tmux--snapshot-generation)
    (when ashub-tmux--snapshot-cancel (funcall ashub-tmux--snapshot-cancel))
    (unless (equal ashub-tmux-snapshot-root (expand-file-name ashub-terminal-runtime-directory))
      (setq ashub-tmux-snapshot nil ashub-tmux-snapshot-time nil))
    (setq ashub-tmux--snapshot-cancel nil ashub-tmux-snapshot-status 'loading
          ashub-tmux-snapshot-root (expand-file-name ashub-terminal-runtime-directory))
    (let ((generation ashub-tmux--snapshot-generation))
      (cl-labels ((accept (value error)
                    (when (= generation ashub-tmux--snapshot-generation)
                      (setq ashub-tmux--snapshot-cancel nil ashub-tmux-snapshot-error error
                            ashub-tmux-snapshot-status (if error 'unknown 'ready)
                            ashub-tmux--snapshot-retry-at (if error (+ (float-time) 5) 0))
                      (unless error
                        (setq ashub-tmux-snapshot value ashub-tmux-snapshot-time (float-time)))
                      (run-hooks 'ashub-tmux-snapshot-change-hook))))
        (condition-case err
            (setq ashub-tmux--snapshot-cancel
                  (ashub-tmux--list-async (lambda (value) (accept value nil))
                                         (lambda (error) (accept nil error))))
          (error (accept nil (error-message-string err))))))))

(defun ashub-tmux-snapshot-fresh-p ()
  "Whether the successful inventory is fresh enough for a scheduling decision."
  (and (equal ashub-tmux-snapshot-root (expand-file-name ashub-terminal-runtime-directory))
       (eq ashub-tmux-snapshot-status 'ready) ashub-tmux-snapshot-time
       (<= 0 (- (float-time) ashub-tmux-snapshot-time) ashub-tmux-snapshot-max-age)))

(defun ashub-tmux-current-snapshot ()
  "Return cached records only for the currently selected registry."
  (when (equal ashub-tmux-snapshot-root (expand-file-name ashub-terminal-runtime-directory))
    ashub-tmux-snapshot))

(defun ashub-tmux-state-source-p (state source &optional storage-only)
  "Whether STATE belongs to SOURCE.  STORAGE-ONLY ignores profile labels."
  (let ((identity (plist-get state :source)))
    (and (equal (plist-get identity :agent) (symbol-name (plist-get source :agent)))
         (equal (plist-get identity :root) (ashub--root (plist-get source :root)))
         (or storage-only (equal (plist-get identity :profile) (plist-get source :profile))))))

(defun ashub-tmux-state-for-session (session &optional states)
  "Find SESSION in cached STATES (default inventory); never probe processes.
History writes are storage-qualified, not merely profile-qualified."
  (let ((runtime-id (plist-get (ashub-session-metadata session) :runtime-id)))
    (seq-find (lambda (state)
                (and (ashub-tmux-state-source-p state (ashub-session-source session) t)
                     (if runtime-id (equal runtime-id (plist-get state :runtimeId))
                       (equal (ashub-session-id session) (plist-get state :sessionId)))))
              (or states (ashub-tmux-current-snapshot)))))

(defun ashub-tmux-session-busy-p (session)
  "Conservatively guard background work for SESSION using fresh inventory.
Unknown/stale inventory requests an async refresh and remains busy.  Render
paths must not call this scheduling function; use cached state instead."
  (if (not (ashub-tmux-snapshot-fresh-p))
      (progn (ashub-tmux-refresh-snapshot) t)
    (seq-some (lambda (state)
                (and (not (member (plist-get state :status) '("finished" "exited" "failed")))
                     (ashub-tmux-state-source-p state (ashub-session-source session) t)
                     (or (equal (plist-get state :status) "unknown")
                         (not (plist-get state :sessionId)) (plist-get state :identityOverflow)
                         (member (ashub-session-id session) (plist-get state :previousSessionIds))
                         (equal (ashub-session-id session) (plist-get state :sessionId)))))
              (ashub-tmux-current-snapshot))))

(provide 'ashub-tmux)
;;; ashub-tmux.el ends here
