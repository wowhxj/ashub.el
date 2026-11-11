;;; terminal-native-child.el --- Independent Emacs lifecycle probe -*- lexical-binding: t; -*-
(require 'ashub-tmux)
(setq ashub-python-program (getenv "ASHUB_TEST_PYTHON")
      ashub-terminal-runtime-directory (getenv "ASHUB_TEST_RUNTIME"))
(let* ((source (list :agent 'claude :root (getenv "ASHUB_TEST_SOURCE")))
       (args (json-parse-string (getenv "ASHUB_TEST_ARGS") :array-type 'list))
       (state (ashub-tmux-ensure source (getenv "ASHUB_TEST_DIRECTORY")
                                 ashub-python-program args process-environment "exact-id"))
       (process-environment (append '("TERM=xterm-256color" "TMUX=") process-environment))
       (_claim (ashub-tmux-controller "claim" state (md5 (format "%s" (emacs-pid)))))
       (client (make-process :name "ashub-test-tty-client" :buffer (get-buffer-create " *test tty*")
                             :connection-type 'pty :coding 'utf-8-unix :noquery t
                             :command (ashub-tmux-attach-command (plist-get state :runtimeId)
                                                                 (plist-get state :generation))))
       (deadline (+ (float-time) 4))
       attached)
  (while (and (process-live-p client) (not attached) (< (float-time) deadline))
    (accept-process-output client 0.04)
    (setq attached
          (with-temp-buffer
            (and (zerop (call-process ashub-tmux-program nil t nil "-S"
                                      (expand-file-name "tmux.sock" ashub-terminal-runtime-directory)
                                      "display-message" "-p" "-t" (concat "=" (plist-get state :name) ":")
                                      "#{session_attached}"))
                 (equal (string-trim (buffer-string)) "1")))))
  (unless attached (error "Independent Emacs did not attach a real tmux PTY client"))
  (with-temp-file (getenv "ASHUB_TEST_OUTPUT")
    (insert (json-serialize state :null-object nil :false-object :json-false)))
  (pcase (getenv "ASHUB_TEST_MODE")
    ("exit" (kill-emacs 0))
    ("kill" (while t (accept-process-output client 0.1)))
    ("finish"
     (ashub-tmux-finish (plist-get state :runtimeId) (plist-get state :generation))
     (kill-emacs 0))))
;;; terminal-native-child.el ends here
