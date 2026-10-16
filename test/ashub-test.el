;;; ashub-test.el --- Isolated acceptance tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'ashub)

;; The optional client is mocked, so declare its policy variable for dynamic tests.
(defvar ghostel-module-auto-install nil)

(defun ashub-test-source (&optional agent root)
  "Return an isolated source for AGENT and ROOT."
  (list :agent (or agent 'claude) :root (or root temporary-file-directory)))

(defun ashub-test-session (&rest overrides)
  "Make a session with OVERRIDES."
  (apply #'ashub-session-create
         (append overrides (list :agent 'claude :source (ashub-test-source)
                                 :id "12345678-abcdef" :cwd temporary-file-directory
                                 :first-message "first user text" :last-active 100))))

(defmacro ashub-test-with-hub (&rest body)
  "Run BODY in a fresh non-displayed Hub without starting a scan."
  `(with-temp-buffer (ashub-mode) ,@body))

(defun ashub-test-install (sessions &optional diagnostics)
  "Install SESSIONS in the current test Hub, with optional DIAGNOSTICS."
  (let* ((source (ashub-session-source (car sessions))) (key (ashub-source-key source)))
    (puthash key (list :source source :status 'loading) ashub--states)
    (ashub--accept-source key sessions diagnostics nil)))

(defun ashub-test-wait (predicate)
  "Wait up to five seconds for PREDICATE while processing timers/process data."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (should (funcall predicate))))

(ert-deftest ashub-identity-is-source-qualified ()
  (let ((a (ashub-test-session))
        (b (ashub-test-session :source (ashub-test-source 'claude "/different")))
        (c (ashub-test-session :agent 'codex :source (ashub-test-source 'codex))))
    (should-not (equal (ashub-session-key a) (ashub-session-key b)))
    (should-not (equal (ashub-session-key a) (ashub-session-key c)))))

(ert-deftest ashub-source-profile-is-not-merged ()
  (let ((a (ashub-test-source)) (b (append (ashub-test-source) '(:profile "other"))))
    (should-not (equal (ashub-source-key a) (ashub-source-key b)))))

(ert-deftest ashub-visibility-only-hides-known-states ()
  (let ((ashub-show-empty nil) (ashub-show-archived nil))
    (dolist (slot '(:empty :internal :archived))
      (should-not (ashub-session-visible-p (ashub-test-session slot t) nil nil ""))
      (should (ashub-session-visible-p (ashub-test-session slot 'unknown) nil nil "")))
    (let ((ashub-show-empty t) (ashub-show-archived t))
      (should (ashub-session-visible-p (ashub-test-session :empty t :archived t) nil nil ""))
      (should-not (ashub-session-visible-p (ashub-test-session :internal t) nil nil "")))))

(ert-deftest ashub-literal-search-full-text-and-full-id ()
  (let ((session (ashub-test-session :first-message (concat (make-string 5000 ?x) " Needle.*")
                                     :cwd "/full/project")))
    (should (ashub-session-visible-p session 'claude "project" "needle.* abcdef"))
    (should-not (ashub-session-visible-p session nil nil "needleZZ"))
    (should-not (ashub-session-visible-p session 'codex nil ""))))

(ert-deftest ashub-sort-unknown-last-and-id-prefixes-disambiguate ()
  (let* ((a (ashub-test-session :id "12345678aaaa" :last-active 10))
         (b (ashub-test-session :id "12345678bbbb" :last-active 20))
         (c (ashub-test-session :id "other" :last-active nil))
         (sessions (list c a b)))
    (should (equal (ashub-sort-sessions sessions) (list b a c)))
    (should (equal (ashub-short-id a sessions) "12345678a"))))

(ert-deftest ashub-row-preview-remains-one-line ()
  (ashub-test-with-hub
   (ashub-test-install (list (ashub-test-session :first-message "hello\nworld\t[thing]")))
   (should (string-match-p "hello world \\[thing\\]" (buffer-string)))
   (should-not (string-match-p "hello\nworld" (buffer-string)))))

(ert-deftest ashub-ui-preserves-selected-session-after-refresh ()
  (ashub-test-with-hub
   (let ((a (ashub-test-session :id "first-id")) (b (ashub-test-session :id "second-id")))
     (ashub-test-install (list a b))
     (goto-char (point-min)) (search-forward "second-i") (beginning-of-line)
     (ashub--render)
     (should (equal (ashub-session-id (ashub--session-at-point)) "second-id")))))

(ert-deftest ashub-collapse-and-full-preview ()
  (ashub-test-with-hub
   (ashub-test-install (list (ashub-test-session :first-message "first\nsecond")))
   (goto-char (point-min)) (search-forward "12345678") (beginning-of-line)
   (ashub-toggle-preview)
   (should (string-match-p "┊ second" (buffer-string)))
   (ashub-toggle-group)
   (should-not (string-match-p "12345678" (buffer-string)))
   (should (string-match-p "+ claude" (buffer-string)))))

(ert-deftest ashub-failed-refresh-retains-marked-old-data ()
  (ashub-test-with-hub
   (let* ((a (ashub-test-session)) (key (ashub-source-key (ashub-session-source a))))
     (ashub-test-install (list a))
     (ashub--accept-source key nil nil "unavailable")
     (should (equal (ashub--all-sessions) (list a)))
     (should (ashub--stale-p a))
     (should (string-match-p "结果不完整" ashub--status))
     (should (string-match-p "旧数据／刷新失败" ashub--status))
     (should (string-match-p "\\[旧\\]" (buffer-string))))))

(ert-deftest ashub-partial-refresh-keeps-only-unresolved-old-records-stale ()
  (ashub-test-with-hub
   (let* ((a (ashub-test-session :id "one")) (b (ashub-test-session :id "two"))
          (key (ashub-source-key (ashub-session-source a))))
     (ashub-test-install (list a b))
     (ashub--accept-source key (list a) '("corrupt file") nil)
     (should (= (length (ashub--all-sessions)) 2))
     (should-not (ashub--stale-p a)) (should (ashub--stale-p b))
     (ashub--accept-source key (list a) nil nil)
     (should (equal (ashub--all-sessions) (list a))))))

(ert-deftest ashub-initial-source-failure-not-empty-success ()
  (ashub-test-with-hub
   (let* ((source (ashub-test-source)) (key (ashub-source-key source)))
     (puthash key (list :source source :status 'loading) ashub--states)
     (ashub--accept-source key nil nil "cannot read")
     (should (eq (plist-get (gethash key ashub--states) :status) 'error))
     (should-not (plist-get (gethash key ashub--states) :loaded)))))

(ert-deftest ashub-refresh-late-generation-is-ignored ()
  (ashub-test-with-hub
   (let ((ashub-sources (list (ashub-test-source))) callbacks)
     (cl-letf (((symbol-function 'ashub-scan-source)
                (lambda (_source callback _error) (push callback callbacks) #'ignore)))
       (ashub-refresh) (ashub-refresh)
       (funcall (cadr callbacks) (list (ashub-test-session :id "obsolete")) nil)
       (should-not (ashub--all-sessions))
       (funcall (car callbacks) (list (ashub-test-session :id "current")) nil)
       (should (equal (ashub-session-id (car (ashub--all-sessions))) "current"))))))

(ert-deftest ashub-cancel-source-suppresses-notifications ()
  (let (success failure callback error-callback cancelled)
    (let* ((source (append (ashub-test-source) (list :scan-function
                                                     (lambda (_s cb err)
                                                       (setq callback cb error-callback err)
                                                       (lambda () (setq cancelled t))))))
           (cancel (ashub-scan-source source (lambda (&rest _) (setq success t))
                                      (lambda (&rest _) (setq failure t)))))
      (funcall cancel) (funcall callback nil nil) (funcall error-callback "late")
      (should cancelled) (should-not success) (should-not failure))))

(ert-deftest ashub-source-timeout-terminates-once ()
  (let ((ashub-scan-timeout 0.01) (calls 0) cancelled)
    (ashub-scan-source
     (append (ashub-test-source) (list :scan-function (lambda (&rest _) (lambda () (setq cancelled t)))))
     (lambda (&rest _) (ert-fail "unexpected success")) (lambda (_err) (cl-incf calls)))
    (ashub-test-wait (lambda () (= calls 1)))
    (should cancelled)))

(ert-deftest ashub-pi-enumeration-is-public-api-only ()
  (let ((source (ashub-test-source 'pi)) result)
    (cl-letf (((symbol-function 'emacs-pi-list-sessions)
               (lambda (callback &rest args)
                 (should (equal (plist-get args :directories) (list (ashub--root temporary-file-directory))))
                 (funcall callback (list :items (list (list :id "pi-id" :path "/session.jsonl"
                                                            :preview "original" :empty nil
                                                            :internal 'unknown :archived 'unknown))))
                 #'ignore)))
      (ashub--scan-pi source (lambda (items _diagnostics) (setq result items)) #'ert-fail)
      (should (equal (ashub-session-first-message (car result)) "original"))
      (should-not (ashub-session-empty (car result))))))

(ert-deftest ashub-dsh-title-and-updatedAt-not-faked-as-message ()
  (let (items diagnostics)
    (cl-letf (((symbol-function 'emacs-dsh-list-sessions)
               (lambda (callback &rest _)
                 (funcall callback '(:source ("host" "nonce" desktop)
                                             :items (((sessionId . "dsh-id") (updatedAt . 999999)
                                                      (projections (values (title . "generated")))))))
                 #'ignore)))
      (ashub--scan-dsh '(:agent dsh :root "configured-host")
                       (lambda (records errors) (setq items records diagnostics errors)) #'ert-fail)
      (should diagnostics)
      (should-not (ashub-session-first-message (car items)))
      (should-not (ashub-session-last-active (car items)))
      (should (eq (ashub-session-empty (car items)) 'unknown)))))

(ert-deftest ashub-terminal-argv-and-profile-environment-no-shell ()
  (dolist (agent '(claude codex hermes))
    (let* ((process-environment nil)
           (session (ashub-test-session :agent agent :id "id-with-;$(shell)"
                                        :source (ashub-test-source agent "/tmp/source with spaces")))
           (command (ashub--terminal-command session "/tmp/project with spaces/")))
      (should (equal (cadr command)
                     (pcase agent
                       ('claude '("--resume" "id-with-;$(shell)"))
                       ('codex '("resume" "id-with-;$(shell)" "--cd" "/tmp/project with spaces/"))
                       ('hermes '("--resume" "id-with-;$(shell)" "--in" "/tmp/project with spaces/")))))
      (should (member (format "%s=%s"
                              (pcase agent ('claude "CLAUDE_CONFIG_DIR") ('codex "CODEX_HOME")
                                     ('hermes "HERMES_HOME"))
                              (ashub--root "/tmp/source with spaces")) (caddr command)))
      (when (eq agent 'hermes) (should (member "/tmp/project with spaces/" (cadr command)))))))

(ert-deftest ashub-source-environment-cannot-switch-storage ()
  (let ((session (ashub-test-session :source '(:agent claude :root "/one"
                                                      :environment ("CLAUDE_CONFIG_DIR=/two")))))
    (should-error (ashub--terminal-command session "/tmp/") :type 'user-error)))

(ert-deftest ashub-missing-directory-requires-explicit-selection ()
  (let ((ashub--directory-overrides (make-hash-table :test #'equal)) (asked 0)
        (session (ashub-test-session :cwd nil)))
    (cl-letf (((symbol-function 'read-directory-name)
               (lambda (&rest _) (cl-incf asked) temporary-file-directory)))
      (should (file-directory-p (ashub--restore-directory session)))
      (ashub--restore-directory session) (should (= asked 1))
      (should-not (ashub-session-cwd session)))))

(ert-deftest ashub-archived-restore-refuses-management-write ()
  (should-error (ashub-open-session (ashub-test-session :archived t)) :type 'user-error))

(ert-deftest ashub-terminal-live-reuse-and-dead-restart ()
  (let ((ashub--instances (make-hash-table :test #'equal))
        (ghostel-module-auto-install 'download)
        (session (ashub-test-session)) (starts 0) buffers processes)
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find) (lambda (_) "/bin/cat"))
                  ((symbol-function 'ghostel-exec)
                   (lambda (buffer _program args &optional _identity)
                     (should-not ghostel-module-auto-install)
                     (should (equal args '("--resume" "12345678-abcdef")))
                     (cl-incf starts) (push buffer buffers)
                     (let ((p (make-pipe-process :name "ashub-test" :noquery t)))
                       (push p processes) p))))
          (ashub--open-terminal session temporary-file-directory #'ignore)
          (ashub--open-terminal session temporary-file-directory #'ignore)
          (should (= starts 1))
          (delete-process (car processes))
          (ashub--open-terminal session temporary-file-directory #'ignore)
          (should (= starts 2))
          (should (eq ghostel-module-auto-install 'download)))
      (dolist (p processes) (when (process-live-p p) (delete-process p)))
      (dolist (b buffers) (when (buffer-live-p b) (kill-buffer b))))))

(ert-deftest ashub-pi-restore-exact-file-and-layout-safe-display ()
  (let ((ashub--opening (make-hash-table :test #'equal)) (called 0) shown)
    (with-temp-buffer
      (let ((target (current-buffer)))
        (cl-letf (((symbol-function 'emacs-pi-open-session)
                   (lambda (path &rest args)
                     (should (equal path "/chosen.jsonl"))
                     (should (eq (plist-get args :display) 'none))
                     (should (equal (plist-get args :session-directory)
                                    (ashub--root temporary-file-directory)))
                     (cl-incf called) (funcall (plist-get args :on-ready) target) target))
                  ((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) (setq shown buffer))))
          (ashub-open-session (ashub-test-session :agent 'pi :path "/chosen.jsonl"
                                                  :source (ashub-test-source 'pi)))
          (should (= called 1)) (should (eq shown target))
          (should (= (hash-table-count ashub--opening) 0)))))))

(ert-deftest ashub-native-concurrent-open-does-not-duplicate ()
  (let ((ashub--opening (make-hash-table :test #'equal)) ready (calls 0)
        (session (ashub-test-session :agent 'pi :source (ashub-test-source 'pi) :path "/chosen")))
    (cl-letf (((symbol-function 'emacs-pi-open-session)
               (lambda (_path &rest args) (cl-incf calls) (setq ready (plist-get args :on-ready)) nil)))
      (ashub-open-session session)
      (should-error (ashub-open-session session) :type 'user-error)
      (should (= calls 1))
      (cl-letf (((symbol-function 'pop-to-buffer) #'ignore)) (funcall ready (current-buffer))))))

(ert-deftest ashub-dsh-cross-host-restore-is-rejected ()
  (cl-letf (((symbol-function 'emacs-dsh--source-identity) (lambda () '("other-host" "nonce" desktop))))
    (should-error (ashub--dsh-source-check
                   (ashub-test-session :metadata '(:native-source ("host" "nonce" desktop))))
                  :type 'user-error)))

(ert-deftest ashub-keymap-and-independent-load ()
  (should (eq (lookup-key ashub-mode-map (kbd "RET")) 'ashub-open))
  (should (eq (lookup-key ashub-mode-map (kbd "/")) 'ashub-search))
  (should (eq (lookup-key ashub-mode-map (kbd "!")) 'ashub-diagnostics))
  (should-not (featurep 'ghostel)))

(ert-deftest ashub-worker-background-integration ()
  (let* ((root (make-temp-file "ashub-fixture-" t))
         (folder (expand-file-name "projects/project" root)) result errors done)
    (unwind-protect
        (progn
          (make-directory folder t)
          (with-temp-file (expand-file-name "session.jsonl" folder)
            (insert (json-serialize '(:type "user" :sessionId "worker-id" :cwd "/work"
                                            :timestamp "2026-01-01T00:00:00Z"
                                            :message (:role "user" :content "worker preview")))) (insert "\n"))
          (ashub-scan-source (ashub-test-source 'claude root)
                             (lambda (items diagnostics) (setq result items errors diagnostics done t))
                             (lambda (error) (setq errors error done t)))
          (ashub-test-wait (lambda () done))
          (should-not errors) (should (= (length result) 1))
          (should (equal (ashub-session-id (car result)) "worker-id")))
      (delete-directory root t))))

(ert-deftest ashub-worker-failure-is-diagnostic ()
  (let (done error)
    (ashub-scan-source (ashub-test-source 'claude "/nonexistent-ashub-fixture")
                       (lambda (&rest _) (ert-fail "false success"))
                       (lambda (message) (setq error message done t)))
    (ashub-test-wait (lambda () done))
    (should (stringp error))))

(ert-deftest ashub-worker-cancel-kills-owned-process-and-buffers ()
  (let ((before (buffer-list))
        (cancel (ashub--scan-local (ashub-test-source 'claude "/nonexistent-ashub-fixture")
                                   (lambda (&rest _) (ert-fail "callback after cancel"))
                                   (lambda (&rest _) (ert-fail "error after cancel")))))
    (funcall cancel)
    (should-not (seq-some (lambda (b) (and (not (memq b before))
                                           (string-prefix-p " *ashub scan" (buffer-name b))))
                          (buffer-list)))))

(ert-deftest ashub-canonical-root-aliases-deduplicate ()
  (let* ((root (make-temp-file "ashub-alias-" t))
         (alias (concat root "-link")))
    (unwind-protect
        (progn
          (make-symbolic-link root alias)
          (let ((ashub-sources (list (ashub-test-source 'claude root)
                                     (ashub-test-source 'claude alias)))
                (ashub-extra-sources nil))
            (should (= (length (ashub-configured-sources)) 1))))
      (when (file-symlink-p alias) (delete-file alias)) (delete-directory root))))

(ert-deftest ashub-unmapped-native-profiles-are-rejected ()
  (dolist (source '((:agent pi :root "/tmp" :profile "other")
                    (:agent dsh :root "other-host")
                    (:agent dsh :root "configured-host" :profile "other")))
    (let ((ashub-sources (list source)) (ashub-extra-sources nil))
      (should-error (ashub-configured-sources)))))

(ert-deftest ashub-source-timeout-cannot-become-success-during-cancel ()
  (let ((ashub-scan-timeout 0.01) done success)
    (ashub-scan-source
     (append (ashub-test-source)
             (list :scan-function (lambda (_source callback _error)
                                    (lambda () (funcall callback nil nil)))))
     (lambda (&rest _) (setq success t)) (lambda (_) (setq done t)))
    (ashub-test-wait (lambda () done)) (should-not success)))

(ert-deftest ashub-native-timeout-ignores-late-readiness ()
  (let ((ashub--opening (make-hash-table :test #'equal))
        (ashub-open-timeout 0.01) ready shown)
    (cl-letf (((symbol-function 'emacs-pi-open-session)
               (lambda (_path &rest args) (setq ready (plist-get args :on-ready)) nil))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) (setq shown t))))
      (ashub-open-session (ashub-test-session :agent 'pi :source (ashub-test-source 'pi) :path "/chosen"))
      (ashub-test-wait (lambda () (= (hash-table-count ashub--opening) 0)))
      (funcall ready (current-buffer)) (should-not shown))))

(ert-deftest ashub-dsh-exact-id-source-and-ready-callback ()
  (let ((ashub--opening (make-hash-table :test #'equal)) shown)
    (cl-letf (((symbol-function 'emacs-dsh--source-identity) (lambda () '("host" "nonce" desktop)))
              ((symbol-function 'emacs-dsh-open-session)
               (lambda (id &rest args)
                 (should (equal id "selected-dsh-id"))
                 (should (eq (plist-get args :display) 'none))
                 (funcall (plist-get args :on-ready) (current-buffer)) #'ignore))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) (setq shown t))))
      (ashub-open-session (ashub-test-session :agent 'dsh :id "selected-dsh-id"
                                              :source '(:agent dsh :root "configured-host")
                                              :metadata '(:native-source ("host" "nonce" desktop))))
      (should shown))))

(ert-deftest ashub-opening-hub-does-not-open-any-session ()
  (let ((ashub-sources (mapcar (lambda (agent)
                                 (list :agent agent :root (if (eq agent 'dsh) "configured-host"
                                                            temporary-file-directory)
                                       :scan-function (lambda (_source callback _error)
                                                        (funcall callback nil nil) #'ignore)))
                               '(claude codex pi dsh hermes)))
        (ashub-extra-sources nil))
    (cl-letf (((symbol-function 'ashub-open-session)
               (lambda (&rest _) (ert-fail "Browsing triggered restore"))))
      (ashub-test-with-hub
       (ashub-refresh)
       (should (= (hash-table-count ashub--states) 5))
       (maphash (lambda (_key state) (should (eq (plist-get state :status) 'ok))) ashub--states)))))

(ert-deftest ashub-clear-filters-does-not-scan ()
  (ashub-test-with-hub
   (ashub-test-install (list (ashub-test-session)))
   (setq ashub--agent-filter 'pi ashub--query "excluded" ashub--project-filter "excluded")
   (cl-letf (((symbol-function 'ashub-scan-source) (lambda (&rest _) (ert-fail "Filter rescanned"))))
     (ashub-clear-filters) (should (= (length (ashub--visible-sessions)) 1)))))

(ert-deftest ashub-missing-executable-does-not-install-or-fallback ()
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil))
            ((symbol-function 'ghostel-exec) (lambda (&rest _) (ert-fail "Unexpected launch"))))
    (let ((ashub--instances (make-hash-table :test #'equal)))
      (should-error (ashub--open-terminal (ashub-test-session) temporary-file-directory #'ignore)
                    :type 'user-error))))

(ert-deftest ashub-dsh-generation-is-part-of-session-identity ()
  (let ((a (ashub-test-session :agent 'dsh :source '(:agent dsh :root "configured-host")
                               :metadata '(:native-source ("host" "old" desktop))))
        (b (ashub-test-session :agent 'dsh :source '(:agent dsh :root "configured-host")
                               :metadata '(:native-source ("host" "new" desktop)))))
    (should-not (equal (ashub-session-key a) (ashub-session-key b)))))

(ert-deftest ashub-search-commit-and-cancel-retain-agent-filter ()
  (ashub-test-with-hub
   (ashub-test-install (list (ashub-test-session)))
   (setq ashub--agent-filter 'claude)
   (cl-letf (((symbol-function 'read-from-minibuffer) (lambda (&rest _) "first user")))
     (ashub-search) (should (equal ashub--query "first user")))
   (cl-letf (((symbol-function 'read-from-minibuffer) (lambda (&rest _) (signal 'quit nil))))
     (condition-case nil (ashub-search) (quit nil))
     (should (equal ashub--query "first user")) (should (eq ashub--agent-filter 'claude)))))

(ert-deftest ashub-dsh-malformed-record-does-not-discard-valid-items ()
  (let (items errors)
    (cl-letf (((symbol-function 'emacs-dsh-list-sessions)
               (lambda (callback &rest _)
                 (funcall callback '(:source ("host" "nonce" desktop)
                                     :items (42 ((sessionId . "valid"))))) #'ignore)))
      (ashub--scan-dsh '(:agent dsh :root "configured-host")
                       (lambda (records diagnostics) (setq items records errors diagnostics)) #'ert-fail)
      (should (= (length items) 1)) (should errors))))

(ert-deftest ashub-invalid-timestamps-and-worker-fields-remain-untrusted ()
  (should-not (ashub--seconds 1.0e100))
  (should-not (ashub--seconds "invalid"))
  (should-error (ashub--json-session (ashub-test-source) '(:id "id" :cwd 42))))

(ert-deftest ashub-worker-malformed-item-is-partial-not-source-failure ()
  (let ((script (make-temp-file "ashub-fake-scanner-" nil ".py")) done items errors)
    (unwind-protect
        (progn
          (with-temp-file script
            (insert "print('{\"kind\":\"item\",\"item\":{\"id\":null}}')\n"
                    "print('{\"kind\":\"item\",\"item\":{\"id\":\"valid\"}}')\n"
                    "print('{\"kind\":\"done\"}')\n"))
          (let ((ashub--scanner-file script))
            (ashub--scan-local (ashub-test-source)
                               (lambda (records diagnostics) (setq items records errors diagnostics done t))
                               (lambda (error) (ert-fail error))))
          (ashub-test-wait (lambda () done))
          (should (= (length items) 1)) (should (= (length errors) 1)))
      (delete-file script))))

(ert-deftest ashub-empty-agent-choice-clears-filter-and-search-can-reset ()
  (dolist (choice '("" "   " "全部"))
    (ashub-test-with-hub
     (ashub-test-install (list (ashub-test-session)))
     (setq ashub--agent-filter 'pi)
     (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) choice)))
       (ashub-filter-agent))
     (should-not ashub--agent-filter)
     (cl-letf (((symbol-function 'read-from-minibuffer) (lambda (&rest _) "no match")))
       (ashub-search) (should-not (ashub--visible-sessions)))
     (cl-letf (((symbol-function 'read-from-minibuffer) (lambda (&rest _) "")))
       (ashub-search) (should (= (length (ashub--visible-sessions)) 1))))))

(ert-deftest ashub-clear-filters-is-discoverable-in-view-and-keymap ()
  (ashub-test-with-hub
   (ashub-test-install (list (ashub-test-session)))
   (should (eq (lookup-key ashub-mode-map (kbd "C")) 'ashub-clear-filters))
   (should (string-match-p "C 清除过滤" (buffer-string)))))

(provide 'ashub-test)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; ashub-test.el ends here
