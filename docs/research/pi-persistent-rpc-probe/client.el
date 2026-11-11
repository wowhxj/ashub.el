;;; client.el --- Isolated persistence probe client -*- lexical-binding: t; -*-

(require 'json)

(let* ((root (getenv "PROBE_ROOT"))
       (label (getenv "PROBE_LABEL"))
       (pending "")
       (state nil)
       (failure nil)
       (cursor-file (expand-file-name "cursor.json" root))
       (cursor (if (file-exists-p cursor-file)
                   (with-temp-buffer
                     (insert-file-contents cursor-file)
                     (json-parse-buffer))
                 0))
       (process
        (make-network-process
         :name "isolated-pi-bridge" :family 'local
         :service (expand-file-name "bridge.sock" root)
         :coding 'utf-8-unix :noquery t
         :filter
         (lambda (_process chunk)
           (setq pending (concat pending chunk))
           (while (string-match "\n" pending)
             (let* ((end (match-end 0))
                    (envelope (json-parse-string (substring pending 0 end)))
                    (seq (gethash "seq" envelope))
                    (record (gethash "record" envelope)))
               (setq pending (substring pending end))
               (unless (= seq (1+ cursor))
                 (error "Replay sequence gap"))
               (setq cursor seq)
               (when (equal (gethash "id" record) (concat "state-" label))
                 (if (gethash "success" record)
                     (setq state (gethash "data" record))
                   (setq failure t)))))))))
  (process-send-string process
                       (concat (json-serialize `(:after ,cursor)) "\n"))
  (process-send-string
   process (concat (json-serialize `(:type "get_state" :id ,(concat "state-" label))) "\n"))
  (let ((deadline (+ (float-time) 15)))
    (while (and (not state) (not failure) (< (float-time) deadline))
      (accept-process-output process 0.1)))
  (unless state (error "No verified RPC state"))
  (with-temp-file (expand-file-name (concat "state-" label ".json") root)
    (insert (json-serialize state)))
  (let ((command (with-temp-buffer
                   (insert-file-contents (expand-file-name "start-command.json" root))
                   (json-parse-buffer))))
    (process-send-string process (concat (json-serialize command) "\n")))
  (with-temp-file cursor-file (insert (number-to-string cursor)))
  (with-temp-file (expand-file-name (concat label ".sent") root)
    (insert "sent"))
  (if (equal label "crash")
      (while t (accept-process-output nil 0.1))
    (delete-process process)
    (kill-emacs 0)))
