;;; readonly-init.el --- Isolated read-only inspection setup -*- lexical-binding: t; -*-

;;; Commentary:
;; Load only in a fresh Emacs -Q instance after explicit user authorization.
;; Set ashub-readonly-client-directories and ashub-readonly-dependency-directory
;; before loading this file.  Never load this helper into an active chat Emacs.
;; No credentials, personal paths or session contents are stored in this file.

;;; Code:
(require 'cl-lib)
(defvar ashub-readonly-client-directories nil
  "Explicit development client directories to put first on load-path.")
(defvar ashub-readonly-dependency-directory nil
  "Existing package directory used only to locate optional dependencies.")
(defvar ashub-readonly-load-errors nil)

(setq load-prefer-newer t
      native-comp-jit-compilation nil
      native-comp-deferred-compilation nil
      make-backup-files nil
      auto-save-default nil
      create-lockfiles nil
      inhibit-startup-screen t)

(let ((root (file-name-directory (directory-file-name (file-name-directory load-file-name))))
      (dependencies
       (when (and ashub-readonly-dependency-directory
                  (file-directory-p ashub-readonly-dependency-directory))
         (cl-remove-if-not
          #'file-directory-p
          (directory-files ashub-readonly-dependency-directory t "\\`[^.]")))))
  (setq load-path (append ashub-readonly-client-directories (list root) dependencies load-path)))

(require 'ashub)

(defun ashub-readonly--deny-open (&rest _arguments)
  "Refuse restore and terminal launches in this preparation instance."
  (user-error "Read-only preparation: real restore/message testing is not authorized"))

(dolist (feature '(emacs-pi emacs-dsh ghostel))
  (condition-case err
      (unless (require feature nil t)
        (push (format "Missing library: %s" feature) ashub-readonly-load-errors))
    (error (push (format "%s: %s" feature (error-message-string err)) ashub-readonly-load-errors))))

(dolist (function '(ashub-open-session emacs-pi-open-session emacs-dsh-open-session ghostel-exec))
  (when (fboundp function)
    (advice-add function :override #'ashub-readonly--deny-open)))

(defun ashub-readonly--skip-dsh (_source _callback on-error)
  "Report skipped DSH inspection through ON-ERROR without querying a Host."
  (funcall on-error "Read-only preparation: real DSH Host intentionally not queried")
  #'ignore)

(setq ashub-sources (ashub-default-sources) ashub-extra-sources nil)
(setf (plist-get (nth 3 ashub-sources) :scan-function) #'ashub-readonly--skip-dsh)

(defun ashub-readonly-show ()
  "Display the guarded Hub in the independent preparation frame."
  (interactive)
  (ashub)
  (setq-local mode-name "ashub READ-ONLY PREPARATION")
  (setq frame-title-format "ashub — read-only preparation (restore disabled)"))

(defun ashub-readonly-report ()
  "Return only version/path/aggregate readiness data, never chat contents."
  (list :emacs emacs-version :pid (emacs-pid)
        :libraries (mapcar (lambda (function)
                             (list function (symbol-file function 'defun)))
                           '(ashub emacs-pi-list-sessions emacs-pi-open-session
                             emacs-dsh-list-sessions emacs-dsh-open-session ghostel-exec))
        :load-errors (reverse ashub-readonly-load-errors)
        :restore-blocked (and (advice-member-p #'ashub-readonly--deny-open 'ashub-open-session) t)
        :terminal-instances (hash-table-count ashub--instances)
        :pending-restores (hash-table-count ashub--opening)
        :sources
        (when-let* ((buffer (get-buffer "*ashub*")))
          (with-current-buffer buffer
            (let (states)
              (maphash (lambda (_key state)
                         (push (list :agent (plist-get (plist-get state :source) :agent)
                                     :status (plist-get state :status)
                                     :records (length (plist-get state :items))
                                     :diagnostics (length (plist-get state :diagnostics))) states))
                       ashub--states)
              (nreverse states))))))

(ashub-readonly-show)

;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; readonly-init.el ends here
