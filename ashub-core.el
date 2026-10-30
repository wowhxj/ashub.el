;;; ashub-core.el --- Session model and filtering -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Package-Requires: ((emacs "29.1"))
;; Version: 0.1.0
;; Keywords: tools, processes

;;; Commentary:
;; Source-qualified identities and pure display/filter helpers for ashub.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup ashub nil "Browse and resume agent sessions." :group 'tools)

(defcustom ashub-sources nil
  "Explicit source plists, or nil for the five default sources.
Each plist has :agent (claude, codex, pi, dsh or hermes), :root (local
storage home; Pi uses its sessions directory), and optional :label,
:profile, :program, :environment, :args, :scan-function, :open-function,
:create-function, :summary-function.  Creation adapters receive
(SOURCE DIRECTORY READY ERROR).  Summary readers receive
(SESSION SUCCESS FAILURE), call SUCCESS with full relevant transcript text,
and return a silent cancellation function; they must not start an agent.
Additional roots must carry their own restore environment/profile.
DSH uses the client's configured Host; additional Hosts need explicit
scan/open functions rather than mutating the client's global transport."
  :type '(repeat plist))
(defcustom ashub-extra-sources nil "Source plists appended to default sources."
  :type '(repeat plist))
(defcustom ashub-show-empty nil "Whether to show reliably empty sessions." :type 'boolean)
(defcustom ashub-show-archived nil "Whether to show archived sessions." :type 'boolean)
(defcustom ashub-python-program "python3" "Python 3.9+ for local background scans."
  :type 'string)
(defcustom ashub-scan-timeout 120 "Maximum seconds per source scan." :type 'number)
(defcustom ashub-group-by 'project "Initial grouping: project or agent."
  :type '(choice (const agent) (const project)))
(defcustom ashub-terminal-open-function nil
  "Optional replacement for ghostel restore.
Called with SESSION, PROGRAM, ARGS, DIRECTORY, ENVIRONMENT and ON-READY.
It must use the supplied exact identity and invoke ON-READY with a buffer
only after establishing a live instance.  It must not send a prompt."
  :type '(choice (const nil) function))

(defcustom ashub-project-relocations nil
  "Alist of (OLD . NEW) project directories renamed or moved on disk.
Sessions recorded under OLD are shown and restored under NEW; agent
history files are never rewritten.  Set interactively with `R' in the Hub."
  :type '(alist :key-type directory :value-type directory))

(cl-defstruct (ashub-session (:constructor ashub-session-create))
  agent source id path cwd first-message last-active time-source
  (internal 'unknown) (empty 'unknown) (archived 'unknown)
  origin title metadata)

(defun ashub--root (path)
  "Return a canonical, local directory name for PATH."
  (unless (and (stringp path) (not (file-remote-p path)))
    (error "Storage root must be a local path: %S" path))
  (directory-file-name (file-truename (expand-file-name path))))

(defun ashub-default-sources ()
  "Return independent defaults without scanning arbitrary disk locations."
  (list (list :agent 'claude :root (or (getenv "CLAUDE_CONFIG_DIR") "~/.claude"))
        (list :agent 'codex :root (or (getenv "CODEX_HOME") "~/.codex"))
        (list :agent 'pi :root
              (expand-file-name "sessions" (or (getenv "PI_CODING_AGENT_DIR") "~/.pi/agent")))
        (list :agent 'dsh :root "configured-host")
        (list :agent 'hermes :root (or (getenv "HERMES_HOME") "~/.hermes"))))

(defun ashub-source-key (source)
  "Return SOURCE's identity, including agent, storage and explicit profile."
  (list (plist-get source :agent)
        (if (eq (plist-get source :agent) 'dsh)
            (plist-get source :root)
          (ashub--root (plist-get source :root)))
        (plist-get source :profile)))

(defun ashub-configured-sources ()
  "Return configured sources with duplicate aliases removed.
Conflicting restore configuration for the same source is an error."
  (let ((seen (make-hash-table :test #'equal)) result)
    (dolist (input (append (or ashub-sources (ashub-default-sources)) ashub-extra-sources))
      (let* ((source (copy-sequence input)) (agent (plist-get source :agent)))
        (unless (memq agent '(claude codex pi dsh hermes))
          (error "Unknown source agent: %S" agent))
        (unless (eq agent 'dsh)
          (setf (plist-get source :root) (ashub--root (plist-get source :root))))
        (when (and (eq agent 'pi) (plist-get source :profile)
                   (not (plist-get source :open-function)))
          (error "Pi runtime profiles require :open-function; :root alone selects session storage"))
        (when (and (eq agent 'dsh)
                   (or (plist-get source :profile)
                       (not (equal (plist-get source :root) "configured-host")))
                   (not (and (plist-get source :scan-function) (plist-get source :open-function))))
          (error "Additional DSH profiles require both :scan-function and :open-function"))
        (let* ((key (ashub-source-key source)) (old (gethash key seen)))
          (cond ((null old) (puthash key source seen) (push source result))
                ((not (equal old source)) (error "Conflicting source configuration: %S" key))))))
    (nreverse result)))

(defun ashub-session-key (session)
  "Return source-qualified identity for SESSION."
  (list (ashub-source-key (ashub-session-source session))
        (and (eq (ashub-session-agent session) 'dsh)
             (plist-get (ashub-session-metadata session) :native-source))
        (or (ashub-session-path session) (ashub-session-id session))))

(defun ashub--one-line (text)
  "Return TEXT without display control characters or physical newlines."
  (replace-regexp-in-string "[[:cntrl:][:space:]]+" " " (or text "")))

(defun ashub--middle (text width)
  "Shorten TEXT in display columns to WIDTH, preserving its tail."
  (if (<= (string-width text) width) text
    (let* ((width (max 3 width)) (left (/ (1- width) 2))
           (right (- width 1 left)))
      (concat (truncate-string-to-width text left) "…"
              (truncate-string-to-width text (string-width text)
                                        (- (string-width text) right))))))

(defun ashub-session-project (session)
  "Return a project label for SESSION; never infer missing cwd from storage."
  (if-let* ((cwd (ashub-session-cwd session)))
      (abbreviate-file-name cwd)
    "[项目未知]"))

(defun ashub-session-cwd-missing-p (session)
  "Whether SESSION records a local absolute cwd that no longer exists."
  (let ((cwd (ashub-session-cwd session)))
    ;; ponytail: one stat per call; cache per render if Hubs grow to thousands of rows.
    (and cwd (file-name-absolute-p cwd) (not (file-remote-p cwd))
         (not (file-directory-p cwd)))))

(defun ashub--relocate-cwd (cwd)
  "Map CWD through `ashub-project-relocations', longest OLD prefix wins."
  (let (best)
    (dolist (pair ashub-project-relocations)
      (let ((old (directory-file-name (expand-file-name (car pair)))))
        (when (and (stringp cwd)
                   (or (string= cwd old) (string-prefix-p (concat old "/") cwd))
                   (> (length old) (length (car best))))
          (setq best (cons old (directory-file-name (expand-file-name (cdr pair))))))))
    (if best (concat (cdr best) (substring cwd (length (car best)))) cwd)))

(defun ashub--matches-p (query values)
  "Match every whitespace-separated word of QUERY against VALUES, literally."
  (let ((haystack (downcase (mapconcat (lambda (x) (format "%s" (or x ""))) values "\n"))))
    (cl-every (lambda (word) (string-match-p (regexp-quote (downcase word)) haystack))
              (split-string (or query "") "[[:space:]]+" t))))

(defun ashub-session-preview (session)
  "Return SESSION's original message, projected prompt, or labelled title."
  (or (ashub-session-first-message session)
      (plist-get (ashub-session-metadata session) :prompt-preview)
      (ashub-session-title session)))

(defun ashub-diagnostic-kind (diagnostic)
  "Classify DIAGNOSTIC; legacy strings and untyped records are read issues."
  (if (and (listp diagnostic) (eq (plist-get diagnostic :kind) 'metadata))
      'metadata 'read))

(defun ashub-diagnostic-text (diagnostic)
  "Render string or structured DIAGNOSTIC without exposing a plist dump."
  (if (stringp diagnostic) diagnostic
    (let ((path (plist-get diagnostic :path)) (message (plist-get diagnostic :message)))
      (if path (format "%s: %s" path message) (format "%s" message)))))

(defun ashub-session-visible-p (session agent project query)
  "Whether SESSION satisfies AGENT, PROJECT, QUERY and visibility settings."
  (and (not (eq (ashub-session-internal session) t))
       (or ashub-show-empty (not (eq (ashub-session-empty session) t)))
       (or ashub-show-archived (not (eq (ashub-session-archived session) t)))
       (or (null agent) (eq agent (ashub-session-agent session)))
       (ashub--matches-p project (list (ashub-session-cwd session)))
       (ashub--matches-p query
                         (list (ashub-session-agent session) (ashub-session-id session)
                               (ashub-session-cwd session) (ashub-session-preview session)))))

(defun ashub-session-display-time (session)
  "Return interaction time, or explicitly attributed source update/create time."
  (or (ashub-session-last-active session)
      (plist-get (ashub-session-metadata session) :updated-at)
      (plist-get (ashub-session-metadata session) :created-at)))

(defun ashub-session-display-time-source (session)
  "Describe which timestamp is used in SESSION's date column."
  (cond ((ashub-session-last-active session) 'interaction)
        ((plist-get (ashub-session-metadata session) :updated-at) 'updated)
        ((plist-get (ashub-session-metadata session) :created-at) 'created)))

(defun ashub-sort-sessions (sessions)
  "Return SESSIONS newest first by attributed display time, unknown dates last."
  (sort (copy-sequence sessions)
        (lambda (a b)
          (let ((ta (ashub-session-display-time a)) (tb (ashub-session-display-time b)))
            (if (equal ta tb)
                (string-lessp (prin1-to-string (ashub-session-key a))
                              (prin1-to-string (ashub-session-key b)))
              (> (or ta 0) (or tb 0)))))))

(defun ashub-short-id (session sessions)
  "Find a distinguishing prefix of SESSION's full ID among SESSIONS."
  (let* ((id (ashub-session-id session)) (width (min 8 (length id))))
    (while (and (< width (length id))
                (cl-some (lambda (other)
                           (let ((oid (ashub-session-id other)))
                             (and (not (equal id oid))
                                  (string-prefix-p (substring id 0 width) oid)))) sessions))
      (setq width (1+ width)))
    (substring id 0 width)))

(provide 'ashub-core)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; ashub-core.el ends here
