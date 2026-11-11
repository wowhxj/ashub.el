;;; native-runtime-integration.el --- Hub/public Pi API vertical probe -*- lexical-binding: t; -*-
;; Run separately with the source emacs-pi repository on load-path.  No user
;; runtime/configuration is read; backend is the controlled fake-pi.py fixture.
(require 'ert)
(require 'ashub)
(require 'emacs-pi)

(defun ashub-native-integration-wait (predicate)
  "Service real pipes until PREDICATE holds, bounded to twelve seconds."
  (let ((deadline (+ (float-time) 12)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil .03))
    (should (funcall predicate))))

(ert-deftest ashub-native-public-pi-api-survives-detach-and-keeps-summary-gated ()
  (let* ((directory (file-truename (make-temp-file "/tmp/ashub-native-pi-" t)))
         (file (expand-file-name "history.jsonl" directory))
         (emacs-pi-runtime-directory (expand-file-name "registry" directory))
         (emacs-pi-persistent t)
         (emacs-pi-executable (expand-file-name "test/fake-pi.py" (file-name-directory (locate-library "emacs-pi"))))
         (ashub-native--cache (make-hash-table :test #'eq)) (ashub-native-change-hook nil)
         (ashub-summary-mode nil)
         (session (ashub-session-create :agent 'pi :source (list :agent 'pi :root directory)
                                        :id "native-integration" :path file))
         buffer failure generation)
    (cl-labels
        ((open ()
           (setq failure nil buffer nil)
           (emacs-pi-open-session file :directory directory :display 'none
                                  :on-ready (lambda (value) (setq buffer value))
                                  :on-error (lambda (value) (setq failure value)))
           (ashub-native-integration-wait (lambda () (or buffer failure)))
           (should-not failure))
         (refresh ()
           (ashub-native-refresh 'pi t)
           (ashub-native-integration-wait (lambda () (ashub-native-fresh-p 'pi)))))
      (with-temp-file file
        (insert (emacs-pi--jencode (emacs-pi--jobject "type" "session" "id" "native-integration" "cwd" directory)) "\n"))
      (unwind-protect
          (progn
            (open) (refresh)
            (should (eq (ashub-native-state-for-session session) 'present))
            (setq generation (plist-get (car (plist-get (ashub-native-cached 'pi) :value)) :generation))
            (should (ashub-native-session-busy-p session))
            (kill-buffer buffer) (setq buffer nil)
            (accept-process-output nil .2)
            (refresh)
            (should (eq (ashub-native-state-for-session session) 'present))
            (should (ashub--session-open-p session))
            (should (ashub-native-session-busy-p session))
            (should (equal generation (plist-get (car (plist-get (ashub-native-cached 'pi) :value)) :generation)))
            (should-not (plist-get (car (plist-get (ashub-native-cached 'pi) :value)) :hasController))
            (open)
            (with-current-buffer buffer (emacs-pi-quit))
            (ashub-native-integration-wait (lambda () (not (buffer-live-p buffer))))
            (accept-process-output nil .3)
            (refresh)
            (should (eq (ashub-native-state-for-session session) 'stopped))
            (should-not (ashub-native-session-busy-p session)))
        ;; Finish only this isolated fixture's own instance, even after failure.
        (when (and (not (buffer-live-p buffer))
                   (not (memq (ashub-native-state-for-session session) '(stopped none))))
          (ignore-errors (open)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (emacs-pi-quit))
          (ashub-native-integration-wait (lambda () (not (buffer-live-p buffer)))))
        (delete-directory directory t)))))
;;; native-runtime-integration.el ends here
