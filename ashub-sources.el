;;; ashub-sources.el --- Asynchronous history adapters -*- lexical-binding: t; -*-

;;; Commentary:
;; Pi and DSH use public client APIs.  Other local stores use a read-only
;; Python subprocess.  No adapter launches an agent to enumerate history.

;;; Code:
(require 'ashub-core)
(require 'json)

(declare-function emacs-pi-list-sessions "emacs-pi-history")
(declare-function emacs-pi-cached-sessions "emacs-pi-history")
(declare-function emacs-dsh-list-sessions "emacs-dsh")

(defconst ashub--scanner-file
  (expand-file-name "ashub-scan.py" (file-name-directory (or load-file-name buffer-file-name)))
  "Scanner shipped alongside this package.")

(defun ashub--seconds (value)
  "Convert producer VALUE to seconds, returning nil for unknown times."
  (condition-case nil
      (let ((seconds
             (cond ((numberp value) value)
                   ((stringp value)
                    (if (string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" value)
                        (string-to-number value)
                      (float-time (date-to-time value))))
                   ((consp value) (float-time value)))))
        (when seconds
          (setq seconds (if (> seconds 100000000000) (/ seconds 1000.0) seconds))
          (when (and (> seconds 0) (< seconds 100000000000)) seconds)))
    (error nil)))

(defun ashub--state-value (value)
  "Convert JSON VALUE to a tri-state boolean."
  (cond ((eq value t) t) ((eq value :false) nil) (t 'unknown)))

(defun ashub--json-session (source value)
  "Normalize worker VALUE from SOURCE into a session."
  (unless (and (stringp (plist-get value :id)) (not (string-empty-p (plist-get value :id))))
    (error "Missing full session ID"))
  (dolist (field '(:path :cwd :first_message :last_user_message :title :summary_revision))
    (unless (or (null (plist-get value field)) (stringp (plist-get value field)))
      (error "Invalid scanner text field: %s" field)))
  (ashub-session-create
   :agent (plist-get source :agent) :source source :id (plist-get value :id)
   :path (plist-get value :path) :cwd (plist-get value :cwd)
   :first-message (plist-get value :first_message)
   :last-active (ashub--seconds (plist-get value :last_active))
   :time-source (plist-get value :time_source)
   :internal (ashub--state-value (plist-get value :internal))
   :empty (ashub--state-value (plist-get value :empty))
   :archived (ashub--state-value (plist-get value :archived))
   :origin (plist-get value :origin) :title (plist-get value :title)
   :metadata (list :summary-revision (plist-get value :summary_revision)
                   :reference
                   (list :first (plist-get value :first_message)
                         :last (plist-get value :last_user_message)
                         :last-user-time (ashub--seconds (plist-get value :last_user_time))))))

(defun ashub--scan-local (source callback on-error)
  "Scan SOURCE in a subprocess; use CALLBACK or ON-ERROR exactly once."
  (let ((program (executable-find ashub-python-program)))
    (unless program (error "Missing Python 3.9+: configure ashub-python-program"))
    (let ((buffer (generate-new-buffer " *ashub scan*"))
          (errors (generate-new-buffer " *ashub scan errors*"))
          (default-directory temporary-file-directory)
          process timer exited done cancelled items diagnostics fatal)
      (cl-labels
          ((cleanup ()
             (when (timerp timer) (cancel-timer timer))
             (when (buffer-live-p buffer) (kill-buffer buffer))
             (when (buffer-live-p errors) (kill-buffer errors)))
           (pump ()
             (setq timer nil)
             (unless cancelled
               (condition-case err
                   (progn
                     (with-current-buffer buffer
                       (goto-char (point-min))
                       (let ((budget 32))
                         (while (and (> budget 0) (search-forward "\n" nil t))
                           (let* ((end (point))
                                  (line (buffer-substring-no-properties (point-min) (1- end)))
                                  (value (json-parse-string line :object-type 'plist :array-type 'list
                                                            :null-object nil :false-object :false)))
                             (delete-region (point-min) end)
                             (pcase (plist-get value :kind)
                               ("item"
                                (condition-case bad
                                    (push (ashub--json-session source (plist-get value :item)) items)
                                  (error (push (error-message-string bad) diagnostics))))
                               ("diagnostic"
                                (push (list :kind (if (equal (plist-get value :category) "metadata")
                                                      'metadata 'read)
                                            :path (plist-get value :path)
                                            :message (plist-get value :message)) diagnostics))
                               ("fatal" (setq fatal (plist-get value :message)))
                               ("done" (setq done t))
                               (_ (error "Unknown scanner protocol record"))))
                           (setq budget (1- budget))))))
                 (error (setq fatal (error-message-string err) exited t)))
               (cond
                ((or fatal
                     (and exited (with-current-buffer buffer (= (buffer-size) 0))))
                 (setq cancelled t)
                 (let ((error-text (when (buffer-live-p errors)
                                     (with-current-buffer errors (buffer-string)))))
                   (when (process-live-p process) (delete-process process))
                   (cleanup)
                   (if (or fatal (not done) (/= (process-exit-status process) 0))
                       (funcall on-error (or fatal (format "Scanner failed: %s" error-text)))
                     (funcall callback (nreverse items) (nreverse diagnostics)))))
                ((and exited (with-current-buffer buffer (not (save-excursion
                                                                (goto-char (point-min))
                                                                (search-forward "\n" nil t)))))
                 (setq fatal "Truncated scanner protocol") (schedule))
                ((with-current-buffer buffer (save-excursion (goto-char (point-min))
                                                             (search-forward "\n" nil t)))
                 (schedule)))))
           (schedule ()
             (unless (or cancelled timer) (setq timer (run-at-time 0 nil #'pump)))))
        (condition-case err
            (setq process
                  (make-process
                   :name "ashub-scan" :buffer nil :stderr errors :noquery t
                   :connection-type 'pipe :coding 'utf-8-unix
                   :command (list program "-B" ashub--scanner-file
                                  (symbol-name (plist-get source :agent))
                                  (ashub--root (plist-get source :root)))
                   :filter (lambda (_process chunk)
                             (unless cancelled
                               (with-current-buffer buffer
                                 (goto-char (point-max)) (insert chunk))
                               (schedule)))
                   :sentinel (lambda (proc _event)
                               (when (memq (process-status proc) '(exit signal failed))
                                 (setq exited t) (schedule)))))
          (error (cleanup) (signal (car err) (cdr err))))
        (lambda ()
          (setq cancelled t)
          (when (process-live-p process) (delete-process process))
          (cleanup))))))

(defun ashub--require-client-api (feature function package)
  "Load FEATURE and require FUNCTION from the optional client PACKAGE."
  (require feature nil t)
  (unless (fboundp function)
    (let ((file (or (car (seq-find (lambda (entry) (member (cons 'provide feature) (cdr entry)))
                                   load-history))
                    (locate-library (symbol-name feature)) "library not found")))
      (error "Missing %s (%s). Install/update %s with M-x package-vc-upgrade, then restart Emacs after ending active chats; Hub will not replace loaded clients"
             function file package))))

(defun ashub--pi-result (source result)
  "Normalize Pi RESULT from SOURCE into (ITEMS DIAGNOSTICS)."
  (let (items (diagnostics (copy-sequence (plist-get result :diagnostics))))
    (dolist (raw (plist-get result :items))
      (condition-case bad
          (let ((id (plist-get raw :id)) (path (plist-get raw :path)))
            (unless (and (stringp id) (stringp path)) (error "Missing Pi ID/path"))
            (when (and (plist-get raw :source)
                       (not (equal (ashub--root (plist-get raw :source))
                                   (ashub--root (plist-get source :root)))))
              (error "Pi returned a different storage source"))
            (push (ashub-session-create
                   :agent 'pi :source source :id id :path path
                   :cwd (plist-get raw :cwd) :first-message (plist-get raw :preview)
                   :last-active (ashub--seconds (plist-get raw :modified))
                   :time-source (plist-get raw :time-source)
                   :internal (if (plist-member raw :internal) (plist-get raw :internal) 'unknown)
                   :empty (if (plist-member raw :empty) (plist-get raw :empty) 'unknown)
                   :archived (if (plist-member raw :archived) (plist-get raw :archived) 'unknown)
                   :title (plist-get raw :name)
                   :metadata
                   (append (list :reference
                                 (list :first (plist-get raw :preview)
                                       :last (plist-get raw :last-preview)
                                       :last-user-time
                                       (ashub--seconds (plist-get raw :last-user-time))))
                           raw)) items))
        (error (push (error-message-string bad) diagnostics))))
    (list (nreverse items) diagnostics)))

(defun ashub-cached-source (source)
  "Return cached (ITEMS DIAGNOSTICS) for SOURCE, or nil when unavailable.
Only the built-in Pi adapter currently supports startup summaries.
Older clients and custom scan functions keep their existing behavior."
  (when (and (eq (plist-get source :agent) 'pi)
             (not (plist-get source :scan-function)))
    (condition-case nil
        (progn
          (require 'emacs-pi-history nil t)
          (when (fboundp 'emacs-pi-cached-sessions)
            (ashub--pi-result
             source (emacs-pi-cached-sessions (list (ashub--root (plist-get source :root)))))))
      (error nil))))

(defun ashub--scan-pi (source callback on-error)
  "Enumerate Pi SOURCE through its public API using CALLBACK and ON-ERROR."
  (ashub--require-client-api 'emacs-pi-history 'emacs-pi-list-sessions 'emacs-pi)
  (emacs-pi-list-sessions
   (lambda (result)
     (condition-case err
         (apply callback (ashub--pi-result source result))
       (error (funcall on-error (error-message-string err)))))
   :directories (list (ashub--root (plist-get source :root))) :on-error on-error))

(defun ashub--scan-dsh (source callback on-error)
  "Enumerate DSH SOURCE through its API using CALLBACK and ON-ERROR."
  (ashub--require-client-api 'emacs-dsh 'emacs-dsh-list-sessions 'emacs-dsh)
  (unless (equal (plist-get source :root) "configured-host")
    (error "Additional DSH Hosts need explicit :scan-function and :open-function"))
  (emacs-dsh-list-sessions
   (lambda (result)
     (condition-case err
         (let (items diagnostics (missing-first 0) (missing-time 0))
           (let ((identity (plist-get result :source)))
             (unless (and (listp identity) (= (length identity) 3)
                          (stringp (car identity)) (stringp (cadr identity))
                          (memq (nth 2 identity) '(desktop managed)))
               (error "DSH omitted a complete authenticated source identity")))
           (dolist (raw (append (plist-get result :items) nil))
             (condition-case bad
                 (let* ((id (alist-get 'sessionId raw))
                        (cwd (alist-get 'cwd raw))
                        (first (alist-get 'firstUserMessage raw))
                        (last (ashub--seconds (alist-get 'lastInteractionAt raw)))
                        (count (alist-get 'userMessageCount raw))
                        (values (alist-get 'values (alist-get 'projections raw)))
                        (outline (alist-get 'turnOutline values))
                        (prompts (and (or (listp outline) (vectorp outline))
                                      (delq nil
                                            (mapcar
                                             (lambda (turn)
                                               (let ((text (and (listp turn)
                                                                (alist-get 'prompt turn))))
                                                 (and (stringp text)
                                                      (not (string-empty-p (string-trim text)))
                                                      text)))
                                             (append outline nil)))))
                        (prompt (car prompts))
                        (last-prompt (car (last prompts)))
                        (last-user-time
                         (ashub--seconds
                          (alist-get 'lastPromptAt (alist-get 'sessionListMetadata values))))
                        (title (alist-get 'title values))
                        (updated (ashub--seconds (alist-get 'updatedAt raw)))
                        (created (ashub--seconds (alist-get 'createdAt raw))))
                   (unless (and (stringp id) (not (string-empty-p id)))
                     (error "DSH item missing full sessionId"))
                   (unless (or (null cwd) (stringp cwd)) (error "Invalid DSH cwd field"))
                   ;; updatedAt and generated titles are not message timestamps/text.
                   (unless (seq-some (lambda (text) (and (stringp text) (not (string-empty-p (string-trim text)))))
                                     (list first prompt title))
                     (cl-incf missing-first))
                   (unless (or last updated created) (cl-incf missing-time))
                   (push (ashub-session-create
                          :agent 'dsh :source source :id id :cwd cwd
                          :first-message (and (stringp first) first) :last-active last
                          :time-source (and last 'message)
                          :empty (if (numberp count) (= count 0) 'unknown)
                          :archived (if (assq 'archived raw)
                                        (ashub--state-value (alist-get 'archived raw)) 'unknown)
                          :origin (alist-get 'origin raw)
                          :title (and (stringp title) (not (string-empty-p (string-trim title))) title)
                          :metadata (list :native-source (plist-get result :source)
                                          :reference (list :first (or (and (stringp first) first) prompt)
                                                           :last last-prompt
                                                           :last-user-time last-user-time)
                                          :prompt-preview (and (stringp prompt)
                                                               (not (string-empty-p (string-trim prompt))) prompt)
                                          :updated-at updated :created-at created)) items))
               (error (push (error-message-string bad) diagnostics))))
           (when (or (> missing-first 0) (> missing-time 0))
             (push (list :kind 'metadata
                         :message (format "DSH: %d 条无可用消息/预览，%d 条无可用时间；预览/标题已标注，来源更新/创建时间以 * 区分"
                                          missing-first missing-time)) diagnostics))
           (funcall callback (nreverse items) (nreverse diagnostics)))
       (error (funcall on-error (error-message-string err)))))
   :on-error on-error))

(defun ashub-scan-source (source callback on-error)
  "Scan SOURCE asynchronously and return a silent cancellation function.
CALLBACK receives (SESSIONS DIAGNOSTICS).  ON-ERROR receives a message.
Timeout, cancellation and even misbehaving custom adapters terminate once."
  (let (finished cancel timer)
    (cl-labels ((finish (function &rest args)
                  (unless finished
                    (setq finished t)
                    (when (timerp timer) (cancel-timer timer))
                    (apply function args))))
      (setq timer (run-at-time ashub-scan-timeout nil
                               (lambda ()
                                 (unless finished
                                   (finish on-error "Source scan timed out")
                                   (when (functionp cancel) (funcall cancel))))))
      (condition-case err
          (setq cancel
                (funcall
                 (or (plist-get source :scan-function)
                     (pcase (plist-get source :agent)
                       ('pi #'ashub--scan-pi) ('dsh #'ashub--scan-dsh) (_ #'ashub--scan-local)))
                 source (lambda (items diagnostics) (finish callback items diagnostics))
                 (lambda (error) (finish on-error (format "%s" error)))))
        (error (finish on-error (error-message-string err))))
      (lambda ()
        (setq finished t)
        (when (timerp timer) (cancel-timer timer))
        (when (functionp cancel) (funcall cancel))))))

(provide 'ashub-sources)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; ashub-sources.el ends here
