;;; ashub-native.el --- Cached native runtime observations -*- lexical-binding: t; -*-

;;; Commentary:
;; Read public Pi/DSH APIs only.  Observation is never a control lease or idle
;; proof.  Rendering reads cached values; only explicit refresh schedules IO.

;;; Code:
(require 'ashub-core)
(require 'cl-lib)
(require 'seq)

(declare-function emacs-pi-inspect-runtimes "emacs-pi-runtime" (on-success &rest args))
(declare-function emacs-dsh-inspect-host "emacs-dsh" (on-success &rest args))

(defvar ashub-native--cache (make-hash-table :test #'eq))
(defvar ashub-native-change-hook nil)
(defvar ashub-native--activities (make-hash-table :test #'equal))
(declare-function emacs-dsh-inspect-session-activity "emacs-dsh" (session-id on-success &rest args))
(defconst ashub-native--max-age 10)

(defun ashub-native--context (agent)
  "Read configuration values for AGENT, without discovery or IO."
  (list (and (eq agent 'dsh)
             (mapcar (lambda (name) (cons name (getenv name))) '("DSH_HOME" "HOME" "APPDATA" "LOCALAPPDATA")))
        (mapcar (lambda (name) (cons name (and (boundp name) (copy-tree (symbol-value name)))))
          (pcase agent
            ('pi '(emacs-pi-runtime-directory emacs-pi-node-executable))
            ('dsh '(emacs-dsh-connection-mode emacs-dsh-managed-home
                    emacs-dsh-managed-command emacs-dsh-managed-arguments
                    emacs-dsh-managed-directory emacs-dsh-runtime-directory
                    emacs-dsh-bridge-file emacs-dsh-desktop-data-directory))))))

(defun ashub-native--load-client (agent)
  "Load AGENT's public definitions, never its runtime."
  (let ((feature (pcase agent ('pi 'emacs-pi) ('dsh 'emacs-dsh)))
        (api (pcase agent ('pi 'emacs-pi-inspect-runtimes) ('dsh 'emacs-dsh-inspect-host))))
    (unless (or (fboundp api) (and (require feature nil t) (fboundp api)))
      (error "Native runtime API unavailable; update the client package"))))

(defun ashub-native--query (agent success failure)
  "Start AGENT's public read-only query, returning silent cancellation."
  (funcall (pcase agent ('pi #'emacs-pi-inspect-runtimes) ('dsh #'emacs-dsh-inspect-host))
           success :on-error failure))

(defun ashub-native-fresh-p (agent)
  "Whether AGENT's cache is a fresh successful observation for this config."
  (let ((entry (gethash agent ashub-native--cache)))
    (and (equal (plist-get entry :context) (ashub-native--context agent))
         (eq (plist-get entry :status) 'ready)
         (< (- (float-time) (or (plist-get entry :time) 0)) ashub-native--max-age))))

(defun ashub-native-cached (agent)
  "Return AGENT's configuration-bound cache entry, without querying anything."
  (let ((entry (gethash agent ashub-native--cache)))
    (when (equal (plist-get entry :context) (ashub-native--context agent)) entry)))

(defun ashub-native--path (value)
  "Normalize local VALUE outside rendering; nil is an unknown scope."
  (when (and (stringp value) (file-name-absolute-p value) (not (file-remote-p value)))
    (condition-case nil (directory-file-name (file-truename value)) (error nil))))

(defun ashub-native--validate (agent value)
  "Validate/copy public VALUE; discard content and normalize paths once."
  (pcase agent
    ('pi
     (unless (listp value) (error "Invalid Pi inventory"))
     (mapcar (lambda (row)
               (unless (and (listp row) (stringp (plist-get row :instance))
                            (member (plist-get row :status)
                                    '("starting" "running" "stopping" "finished" "exited" "failed" "unknown")))
                 (error "Invalid Pi runtime"))
               (list :instance (plist-get row :instance) :generation (plist-get row :generation)
                     :status (plist-get row :status) :sessionId (plist-get row :sessionId)
                     :sessionFile (ashub-native--path (plist-get row :sessionFile))
                     :sessionDirectory (ashub-native--path (plist-get row :sessionDirectory))
                     :hasController (plist-get row :hasController))) value))
    ('dsh
     (let ((source (plist-get value :source)) (caps (plist-get value :capabilities)))
       (unless (and (equal (plist-get value :status) "running") (listp source) (= (length source) 3)
                    (stringp (car source)) (stringp (cadr source)) (memq (nth 2 source) '(desktop managed))
                    (listp (plist-get value :sessions)))
         (error "Invalid DSH runtime"))
       (list :source (copy-tree source)
             :capabilities (list :mode (nth 2 source) :quit 'detach :finish-session nil
                                 :ownership (if (memq (plist-get caps :ownership) '(external independent emacs))
                                                (plist-get caps :ownership) 'unknown)
                                 :configured-persistence (eq (plist-get caps :configured-persistence) t)
                                 :shutdown-host (and (eq (nth 2 source) 'managed) (eq (plist-get caps :shutdown-host) t)))
             :sessions (mapcar (lambda (row)
                                 (unless (and (stringp (plist-get row :session-id))
                                              (memq (plist-get row :backend-state) '(present not-running unknown)))
                                   (error "Invalid DSH runtime row"))
                                 (list :session-id (plist-get row :session-id)
                                       :backend-state (plist-get row :backend-state)))
                               (plist-get value :sessions)))))))

(defun ashub-native-refresh (agent &optional force)
  "Refresh AGENT asynchronously; FORCE cancels only the older query.
Failed/unavailable clients never start a backend or silently imply absence."
  (unless (memq agent '(pi dsh)) (error "Unsupported native runtime"))
  (let* ((previous (gethash agent ashub-native--cache))
         (same (equal (plist-get previous :context) (ashub-native--context agent))))
    (unless (and (not force) same
                 (or (eq (plist-get previous :status) 'loading)
                     (ashub-native-fresh-p agent)
                     (< (float-time) (or (plist-get previous :retry-at) 0))))
      (when (functionp (plist-get previous :cancel)) (funcall (plist-get previous :cancel)))
      (let ((entry (list :status 'loading :context (ashub-native--context agent)
                         :value (and same (plist-get previous :value))
                         :time (and same (plist-get previous :time))
                         :cancel nil :error nil :retry-at 0)) done)
        (puthash agent entry ashub-native--cache)
        (cl-labels
            ((finish (value failure)
               (unless done
                 (setq done t)
                 (when (and (eq entry (gethash agent ashub-native--cache))
                            (equal (plist-get entry :context) (ashub-native--context agent)))
                   (setf (plist-get entry :cancel) nil
                         (plist-get entry :status) (if failure 'unknown 'ready)
                         (plist-get entry :error) (and failure "Native runtime state unavailable; refresh/update the client")
                         (plist-get entry :retry-at) (if failure (+ (float-time) 5) 0))
                   (unless failure
                     (setf (plist-get entry :value) value (plist-get entry :time) (float-time)))
                   (run-hooks 'ashub-native-change-hook)))))
          (condition-case nil
              (progn
                (ashub-native--load-client agent)
                ;; Loading definitions may introduce configuration defaults.
                (setf (plist-get entry :context) (ashub-native--context agent))
                (let ((cancel (ashub-native--query
                               agent
                               (lambda (value)
                                 (let ((parsed (condition-case nil (ashub-native--validate agent value) (error :invalid))))
                                   (if (eq parsed :invalid) (finish nil t) (finish parsed nil))))
                               (lambda (_failure) (finish nil t)))))
                  (unless done (setf (plist-get entry :cancel) cancel))))
            (error (finish nil t))))))))

(defun ashub-native-refresh-sources (sources &optional force)
  "Refresh only native agents represented by SOURCES; never start a backend."
  (dolist (agent (delete-dups (mapcar (lambda (source) (plist-get source :agent)) sources)))
    (when (memq agent '(pi dsh)) (ashub-native-refresh agent force))))

(defun ashub-native--within (file directory)
  "Compare normalized FILE and DIRECTORY lexically, with no filesystem IO."
  (and file directory (or (equal file directory) (string-prefix-p (file-name-as-directory directory) file))))

(defun ashub-native-state-for-session (session)
  "Read SESSION's cached observation, regardless of freshness, without IO.
Return present/stopped/none/not-running/unknown.  Unknown is not open or idle."
  (let* ((agent (ashub-session-agent session)) (entry (ashub-native-cached agent))
         (value (plist-get entry :value)))
    (cond
     ((not (plist-get entry :time)) 'unknown)
     ((eq agent 'pi)
      (let* ((file (ashub-session-path session)) (root (plist-get (ashub-session-source session) :root))
             (matches (seq-filter (lambda (row) (and file (equal file (plist-get row :sessionFile)))) value)))
        (cond
         ((> (length matches) 1) 'unknown)
         (matches (pcase (plist-get (car matches) :status)
                    ((or "running" "starting" "stopping") 'present)
                    ((or "finished" "exited" "failed") 'stopped) (_ 'unknown)))
         ;; Until alias/fork quiescence is proven, another live owner under
         ;; this storage root also prevents speculative summary dispatch.
         ((seq-some (lambda (row)
                      (and (not (member (plist-get row :status) '("finished" "exited" "failed")))
                           (or (and (not (plist-get row :sessionFile)) (not (plist-get row :sessionDirectory)))
                               (ashub-native--within (plist-get row :sessionFile) root)
                               (ashub-native--within (plist-get row :sessionDirectory) root)
                               (ashub-native--within root (plist-get row :sessionDirectory))))) value) 'unknown)
         (t 'none))))
     ((eq agent 'dsh)
      (if (not (equal (plist-get (ashub-session-metadata session) :native-source) (plist-get value :source))) 'unknown
        (let ((rows (seq-filter (lambda (row) (equal (ashub-session-id session) (plist-get row :session-id)))
                                (plist-get value :sessions))))
          (if (= (length rows) 1) (plist-get (car rows) :backend-state) 'unknown))))
     (t 'unknown))))

(defun ashub-native-session-present-p (session)
  "Whether cached evidence identifies a possibly live backend for SESSION.
A matched unknown Pi owner is retained in the live view, not called absent.
Unscoped uncertainty does not fabricate a backend for every history row."
  (or (eq (ashub-native-state-for-session session) 'present)
      (and (eq (ashub-session-agent session) 'pi) (ashub-session-path session)
           (seq-some (lambda (row)
                       (and (equal (ashub-session-path session) (plist-get row :sessionFile))
                            (equal (plist-get row :status) "unknown")))
                     (plist-get (ashub-native-cached 'pi) :value)))))

(defun ashub-native--activity-key (session)
  "Exact authenticated Host generation and SESSION identity."
  (list (plist-get (ashub-session-metadata session) :native-source) (ashub-session-id session)))

(defun ashub-native-activity-fresh-p (session)
  "Whether SESSION has a fresh source-pinned passive execution sample."
  (let* ((key (ashub-native--activity-key session)) (entry (gethash key ashub-native--activities)))
    (and (ashub-native-fresh-p 'dsh)
         (equal (car key) (plist-get (plist-get (ashub-native-cached 'dsh) :value) :source))
         (equal (plist-get entry :context) (ashub-native--context 'dsh))
         (eq (plist-get entry :status) 'ready)
         (< (- (float-time) (or (plist-get entry :time) 0)) ashub-native--max-age))))

(defun ashub-native-refresh-activity (session &optional force)
  "Passively sample SESSION, without activation, transcript or agent control."
  (let* ((key (ashub-native--activity-key session)) (previous (gethash key ashub-native--activities))
         (context (ashub-native--context 'dsh)))
    (when (and (eq (ashub-session-agent session) 'dsh) (car key)
               (ashub-native-fresh-p 'dsh)
               (equal (car key) (plist-get (plist-get (ashub-native-cached 'dsh) :value) :source))
               (or force (not (and (equal context (plist-get previous :context))
                                   (or (eq (plist-get previous :status) 'loading)
                                       (ashub-native-activity-fresh-p session)
                                       (< (float-time) (or (plist-get previous :retry-at) 0)))))))
      (when (functionp (plist-get previous :cancel)) (funcall (plist-get previous :cancel)))
      (let ((entry (list :context context :status 'loading :time nil :value nil :cancel nil :retry-at 0)) done)
        (puthash key entry ashub-native--activities)
        (cl-labels
            ((finish (value failure)
               (unless done
                 (setq done t)
                 (when (and (eq entry (gethash key ashub-native--activities))
                            (equal context (ashub-native--context 'dsh)))
                   (setf (plist-get entry :cancel) nil (plist-get entry :status) (if failure 'unknown 'ready)
                         (plist-get entry :retry-at) (if failure (+ (float-time) 5) 0)
                         (plist-get entry :time) (and (not failure) (float-time))
                         (plist-get entry :value) (and (not failure) (plist-get value :activity)))
                   (run-hooks 'ashub-native-change-hook)))))
          (condition-case nil
              (let ((cancel
                     (emacs-dsh-inspect-session-activity
                      (ashub-session-id session)
                      (lambda (value)
                        (finish value
                                (not (and (equal (plist-get value :source) (car key))
                                          (equal (plist-get value :session-id) (cadr key))
                                          (memq (plist-get value :activity) '(idle busy input-required unknown))
                                          (integerp (plist-get value :queue-count))
                                          (integerp (plist-get value :pending-input-count))
                                          (>= (plist-get value :queue-count) 0) (>= (plist-get value :pending-input-count) 0)
                                          (or (not (eq (plist-get value :activity) 'idle))
                                              (and (plist-member value :running) (null (plist-get value :running))
                                                   (plist-member value :active) (memq (plist-get value :active) '(t nil))
                                                   (integerp (plist-get value :cursor)) (>= (plist-get value :cursor) -1)
                                                   (= (plist-get value :queue-count) 0)
                                                   (= (plist-get value :pending-input-count) 0)))))))
                      :on-error (lambda (_failure) (finish nil t)))))
                (unless done (setf (plist-get entry :cancel) cancel)))
            (error (finish nil t))))))))

(defun ashub-native-refresh-activities (sessions)
  "Refresh at most two eligible stale session samples per scheduler pass."
  (let ((remaining 2) (context (ashub-native--context 'dsh))
        (source (plist-get (plist-get (ashub-native-cached 'dsh) :value) :source)) remove)
    (maphash (lambda (key entry)
               (if (or (not (equal context (plist-get entry :context))) (not (equal (car key) source)))
                   (progn (when (functionp (plist-get entry :cancel)) (funcall (plist-get entry :cancel)))
                          (push key remove))
                 (when (eq (plist-get entry :status) 'loading) (cl-decf remaining)))) ashub-native--activities)
    (dolist (key remove) (remhash key ashub-native--activities))
    (dolist (session sessions)
      (when (and (> remaining 0) (eq (ashub-session-agent session) 'dsh)
                 (not (ashub-native-activity-fresh-p session)))
        (let ((entry (gethash (ashub-native--activity-key session) ashub-native--activities)))
          (unless (and (equal (plist-get entry :context) (ashub-native--context 'dsh))
                       (or (eq (plist-get entry :status) 'loading)
                           (< (float-time) (or (plist-get entry :retry-at) 0))))
            (cl-decf remaining)
            (ashub-native-refresh-activity session)))))))

(defun ashub-native-session-busy-p (session)
  "Conservative dispatch gate; never infer idle from process absence alone.
Pi permits fresh no-owner/ended observations.  DSH requires a separate,
exact-source native wait idle sample; list.running=false never proves idle."
  (let ((agent (ashub-session-agent session)))
    (or (not (ashub-native-fresh-p agent))
        (and (eq agent 'dsh)
             (or (not (ashub-native-activity-fresh-p session))
                 (not (eq (plist-get (gethash (ashub-native--activity-key session) ashub-native--activities) :value) 'idle))))
        ;; A stopped exact record cannot overrule another possibly writing
        ;; owner in the same storage scope (e.g. an unreviewed fork alias).
        (and (eq agent 'pi)
             (seq-some (lambda (row)
                    (let ((root (plist-get (ashub-session-source session) :root)))
                      (and (not (member (plist-get row :status) '("finished" "exited" "failed")))
                           (or (and (not (plist-get row :sessionFile)) (not (plist-get row :sessionDirectory)))
                               (ashub-native--within (plist-get row :sessionFile) root)
                               (ashub-native--within (plist-get row :sessionDirectory) root)
                               (ashub-native--within root (plist-get row :sessionDirectory))))))
                  (plist-get (ashub-native-cached 'pi) :value)))
        (and (eq agent 'pi) (not (memq (ashub-native-state-for-session session) '(none stopped)))))))

(provide 'ashub-native)
;;; ashub-native.el ends here
