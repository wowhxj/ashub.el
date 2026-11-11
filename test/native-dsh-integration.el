;;; native-dsh-integration.el --- Real isolated DSH/public Hub probe -*- lexical-binding: t; -*-
;; Run separately with ASHUB_DSH_REAL=1 and the source emacs-dsh on load-path.
;; Explicitly creates only a disposable Host + empty session; never sends a
;; prompt, approval reply, cancellation, model request or Desktop shutdown.
(require 'ert)
(require 'ashub)
(require 'emacs-dsh)

(defun ashub-dsh-integration-wait (predicate)
  "Service process callbacks until PREDICATE, bounded to fifteen seconds."
  (let ((end (+ (float-time) 15)))
    (while (and (not (funcall predicate)) (< (float-time) end))
      (accept-process-output nil .03))
    (should (funcall predicate))))

(ert-deftest ashub-native-real-dsh-idle-proof-allows-closed-summary-without-activation ()
  (skip-unless (equal (getenv "ASHUB_DSH_REAL") "1"))
  (let* ((root (file-truename (make-temp-file "/tmp/ashub-passive-dsh-" t)))
         (default-directory root) (process-environment (copy-sequence process-environment))
         (emacs-dsh-connection-mode 'managed) (emacs-dsh-managed-persistent t)
         (emacs-dsh-managed-command (or (getenv "DSH_EXECUTABLE") "dsh"))
         (emacs-dsh-managed-home (expand-file-name "home" root))
         (emacs-dsh-managed-directory root) (emacs-dsh-runtime-directory (expand-file-name "runtime" root))
         (ashub-native--cache (make-hash-table :test #'eq))
         (ashub-native--activities (make-hash-table :test #'equal)) (ashub-native-change-hook nil)
         (ashub-summary-mode nil) connection failure chat session source generation)
    (set-file-modes root #o700)
    (setenv "DSH_HOME" emacs-dsh-managed-home)
    (setenv "DSH_TELEMETRY_DISABLED" "1")
    (setenv "DEEPSEEK_API_KEY" "fixture-not-a-real-model-key")
    (unwind-protect
        (progn
          (emacs-dsh--managed-start (lambda (value error) (setq connection value failure error)))
          (ashub-dsh-integration-wait (lambda () (or connection failure)))
          (should-not failure)
          (emacs-dsh-create-session root :display 'none :on-ready (lambda (value) (setq chat value))
                                    :on-error (lambda (error) (setq failure error)))
          (ashub-dsh-integration-wait (lambda () (or chat failure)))
          (should-not failure)
          (setq source (buffer-local-value 'emacs-dsh--source chat)
                generation (cadr source)
                session (ashub-session-create :agent 'dsh :source '(:agent dsh) :id (buffer-local-value 'emacs-dsh--session-id chat)
                                              :metadata (list :native-source source)))
          (with-current-buffer chat (emacs-dsh-quit))
          (should-not (buffer-live-p chat))
          ;; The Hub path is restricted to public read-only APIs.  Any attempt
          ;; to start/activate/open a chat now is a failure, not a fallback.
          (cl-letf (((symbol-function 'emacs-dsh--managed-start) (lambda (&rest _) (error "Inspection started a Host")))
                    ((symbol-function 'emacs-dsh-open-session) (lambda (&rest _) (error "Inspection opened a chat")))
                    ((symbol-function 'emacs-dsh-create-session) (lambda (&rest _) (error "Inspection created a session"))))
            (ashub-native-refresh 'dsh t)
            (ashub-dsh-integration-wait (lambda () (ashub-native-fresh-p 'dsh)))
            (should (ashub-native-session-busy-p session))
            (ashub-native-refresh-activities (list session))
            (ashub-dsh-integration-wait (lambda () (ashub-native-activity-fresh-p session)))
            (should-not (ashub-native-session-busy-p session))
            (should-not (ashub-summary--open-p session))
            (should (equal generation (cadr (plist-get (plist-get (ashub-native-cached 'dsh) :value) :source))))
            ;; No extension-event consumer was registered by this probe.
            (should-not (buffer-live-p chat))))
      (when (buffer-live-p chat) (kill-buffer chat))
      ;; Explicitly stop only the disposable managed Host this test created.
      (let (stopped)
        (emacs-dsh-runtime-shutdown (lambda (_state error) (setq stopped t failure error)))
        (ashub-dsh-integration-wait (lambda () stopped))
        (should-not failure))
      (delete-directory root t))))
;;; native-dsh-integration.el ends here
