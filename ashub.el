;;; ashub.el --- Browse and resume agent sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Version: 0.1.0
;; URL: https://github.com/wowhxj/ashub.el
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, processes, convenience

;;; Commentary:
;; M-x ashub browses configured Claude, Codex, Pi, DSH and Hermes history.
;; Loading/refreshing never resumes a session.  RET is the explicit restore
;; action.  Local scans require Python 3.9+; Pi and DSH use public client APIs.

;;; Code:
(require 'ashub-core)
(require 'ashub-sources)
(require 'ashub-open)
(require 'help-mode)
(require 'text-property-search)

(declare-function ashub--opening-summary "ashub-open")
(declare-function ashub-create-session "ashub-open")

(defvar-local ashub--states nil "Source state table; results are memory-only.")
(defvar-local ashub--generation 0 "Refresh generation, rejects late callbacks.")
(defvar-local ashub--agent-filter nil)
(defvar-local ashub--project-filter nil)
(defvar-local ashub--query "")
(defvar-local ashub--grouping nil)
(defvar-local ashub--collapsed nil)
(defvar-local ashub--expanded nil)
(defvar-local ashub--status "")
(defvar-local ashub--delete-marks nil "Session keys marked for permanent deletion.")

(defun ashub--source-label (source)
  "Return an unambiguous readable label for SOURCE."
  (ashub--one-line
   (or (plist-get source :label)
       (format "%s:%s%s" (plist-get source :agent)
               (if (eq (plist-get source :agent) 'dsh) (plist-get source :root)
                 (abbreviate-file-name (ashub--root (plist-get source :root))))
               (if (plist-get source :profile) (format " [%s]" (plist-get source :profile)) "")))))

(defun ashub--all-sessions ()
  "Return all retained sessions in this Hub, without filtering."
  (let (items)
    (when ashub--states
      (maphash (lambda (_key state) (setq items (append (plist-get state :items) items))) ashub--states))
    items))

(defun ashub--visible-sessions ()
  "Return filtered sessions ordered by their attributed display date."
  (ashub-sort-sessions
   (seq-filter (lambda (item)
                 (ashub-session-visible-p item ashub--agent-filter ashub--project-filter ashub--query))
               (ashub--all-sessions))))

(defun ashub--group-name (session)
  "Return SESSION's group label in the selected grouping."
  (if (eq ashub--grouping 'project)
      (ashub-session-project session)
    (symbol-name (ashub-session-agent session))))

(defun ashub--stale-p (session)
  "Whether SESSION is retained from a failed/incomplete refresh."
  (let ((state (gethash (ashub-source-key (ashub-session-source session)) ashub--states)))
    (or (eq (plist-get state :status) 'stale)
        (member (ashub-session-key session) (plist-get state :stale-keys)))))

(defun ashub--preview-text (session)
  "Return labelled display text without treating projections as raw messages."
  (cond ((ashub-session-first-message session) (ashub-session-first-message session))
        ((plist-get (ashub-session-metadata session) :prompt-preview)
         (concat "[预览] " (plist-get (ashub-session-metadata session) :prompt-preview)))
        ((ashub-session-title session) (concat "[标题] " (ashub-session-title session)))
        (t "[首条用户消息未知]")))

(defun ashub--insert-row (session sessions)
  "Insert single-line table row for SESSION among SESSIONS."
  (let* ((start (point)) (key (ashub-session-key session))
         (width (max 40 (window-body-width (get-buffer-window (current-buffer)))))
         (id (ashub-short-id session sessions))
         (time (if-let* ((seconds (ashub-session-display-time session)))
                   (concat (format-time-string "%Y-%m-%d %H:%M" (seconds-to-time seconds))
                           (if (memq (ashub-session-display-time-source session) '(updated created)) "*" ""))
                 "时间未知"))
         (project-width (max 10 (min 28 (/ width 5))))
         (preview (ashub--one-line (ashub--preview-text session)))
         (prefix (format (format "  %%s %%-7s %%-17s %%-%ds %%-%ds " (max 8 (length id)) project-width)
                         (if (gethash key ashub--delete-marks) "D" " ")
                         (ashub-session-agent session) time id
                         (ashub--middle (ashub-session-project session) project-width)))
         (prefix (concat prefix (if (gethash key ashub--opening) "[恢复中] " ""))))
    (insert prefix
            (truncate-string-to-width preview (max 12 (- width (string-width prefix) 5)) nil nil "…")
            (if (ashub--stale-p session) " [旧]" "") "\n")
    (when (gethash key ashub--expanded)
      (insert "    ┊ " (replace-regexp-in-string "\n" "\n    ┊ "
                                                 (ashub--preview-text session)) "\n"))
    (add-text-properties start (point) (list 'ashub-session session 'ashub-key key
                                             'rear-nonsticky t))
    ;; Exclude every newline: highlighting it can paint the next line's margin.
    (let ((end (point)))
      (save-excursion
        (goto-char start)
        (while (< (point) end)
          (let ((hover (make-overlay (point) (line-end-position) nil t nil)))
            (overlay-put hover 'ashub-row t)
            (overlay-put hover 'mouse-face 'highlight)
            (overlay-put hover 'evaporate t))
          (forward-line 1))))))

(defun ashub--render ()
  "Redraw the Hub, preserving selected identity and window position."
  (let* ((key (get-text-property (point) 'ashub-key))
         (column (current-column)) (old-point (point))
         (window (get-buffer-window (current-buffer)))
         (window-start-key (and window (get-text-property (window-start window) 'ashub-key)))
         (sessions (ashub--visible-sessions))
         (groups (make-hash-table :test #'equal)) order pending failures reads notes
         (inhibit-read-only t))
    (dolist (session sessions)
      (let ((name (ashub--group-name session)))
        (unless (gethash name groups) (push name order))
        (puthash name (cons session (gethash name groups)) groups)))
    (when ashub--states
      (maphash
       (lambda (_key state)
         (let* ((status (plist-get state :status))
                (source (plist-get state :source))
                (label (ashub--source-label source))
                (diagnostics (plist-get state :diagnostics))
                (metadata-count (cl-count-if (lambda (note) (eq (ashub-diagnostic-kind note) 'metadata)) diagnostics))
                (read-count (- (length diagnostics) metadata-count)))
           (when (eq status 'loading) (push label pending))
           (if (memq status '(error stale))
               (push (concat label (if (eq status 'stale) "（旧数据／刷新失败）" "")) failures)
             (when (> read-count 0) (push (format "%s（%d项）" label read-count) reads)))
           (when (> metadata-count 0) (push (format "%s（%d项）" label metadata-count) notes))))
       ashub--states))
    (let ((total (length (ashub--all-sessions))))
      (setq ashub--status
            (concat "ashub"
                    (when-let* ((opening (ashub--opening-summary)))
                      (concat "  " opening))
                    (format "  显示 %d/已载入 %d（过滤/隐藏 %d）"
                            (length sessions) total (- total (length sessions)))
                    (if pending (format "  扫描中：%s" (string-join (nreverse pending) ", ")) "")
                    (if failures (format "  来源失败：%s" (string-join (nreverse failures) ", ")) "")
                    (if reads (format "  读取异常：%s" (string-join (nreverse reads) ", ")) "")
                    (if notes (format "  字段缺失：%s" (string-join (nreverse notes) ", ")) "")
                    (if (or failures reads notes) "  [! 诊断]" ""))))
    (setq header-line-format `(:eval (propertize ashub--status 'face
                                                 ',(if (or failures reads) 'warning 'mode-line))))
    (erase-buffer)
    (insert (propertize "Agent Session Hub\n" 'face 'bold))
    (insert (format "分组:%s  agent:%s  项目:%s  搜索:%s\n"
                    ashub--grouping (or ashub--agent-filter "全部")
                    (ashub--one-line (or ashub--project-filter "全部")) (ashub--one-line ashub--query)))
    (insert "N 新建  RET 恢复  n/p 移动  / 搜索  a agent  o 项目  C 清除过滤  c 分组  TAB 折叠  g 刷新  e 展开  d 标记删除  x 执行  i 详情  ! 诊断\n")
    (insert "快速定位：1 Claude  2 Codex  3 Pi  4 DSH  5 Hermes（保留项目/搜索筛选）\n\n")
    (when (seq-some (lambda (session) (memq (ashub-session-display-time-source session) '(updated created))) sessions)
      (insert "日期 *：来源更新时间/创建时间（不是已验证的交互时间）\n\n"))
    (when ashub--states
      (maphash
       (lambda (_key state)
         (when (and (eq (plist-get state :status) 'error) (null (plist-get state :items)))
           (insert (propertize
                    (format "%s 无法加载：%s  [! 完整诊断]\n"
                            (ashub--source-label (plist-get state :source))
                            (truncate-string-to-width
                             (ashub--one-line (ashub-diagnostic-text (car (plist-get state :diagnostics)))) 140 nil nil "…"))
                    'face 'warning))))
       ashub--states))
    (if (null sessions) (insert "没有符合当前过滤条件的会话；请查看顶部扫描状态及诊断。\n")
      (dolist (name (nreverse order))
        (let* ((start (point)) (folded (gethash name ashub--collapsed))
               (group (nreverse (gethash name groups))))
          (insert (propertize (format "%s %s (%d)\n" (if folded "+" "−") (ashub--one-line name)
                                      (length group)) 'face 'bold))
          (add-text-properties start (point) (list 'ashub-group name 'ashub-key (list 'group name)))
          (unless folded (dolist (session group) (ashub--insert-row session sessions))))))
    (goto-char (point-min))
    (let ((match (and key (text-property-search-forward 'ashub-key key #'equal))))
      (if match
          (progn (goto-char (prop-match-beginning match)) (move-to-column column))
        (goto-char (min old-point (point-max)))))
    (when (and window window-start-key)
      (save-excursion
        (goto-char (point-min))
        (when-let* ((match (text-property-search-forward 'ashub-key window-start-key #'equal)))
          (set-window-start window (prop-match-beginning match) t))))))

(defun ashub--refresh-opening-display ()
  "Update pending-restore feedback in every live Hub without selecting it."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'ashub-mode) (ashub--render)))))

(add-hook 'ashub-open-state-change-hook #'ashub--refresh-opening-display)

(defun ashub--cancel-scans ()
  "Cancel background work and reject callbacks from the old generation."
  (cl-incf ashub--generation)
  (when ashub--states
    (maphash (lambda (_key state)
               (when (functionp (plist-get state :cancel))
                 (funcall (plist-get state :cancel)))
               (setf (plist-get state :cancel) nil)
               (when (eq (plist-get state :status) 'loading)
                 (setf (plist-get state :status) (if (plist-get state :loaded) 'stale 'error)
                       (plist-get state :diagnostics) '("扫描已取消；未确认数据已刷新"))))
             ashub--states)))

(defun ashub--accept-source (key items diagnostics failure)
  "Commit source KEY's ITEMS/DIAGNOSTICS, preserving old results on FAILURE."
  (let* ((state (gethash key ashub--states)) (old (plist-get state :items)))
    (setf (plist-get state :cancel) nil (plist-get state :stale-keys) nil)
    (if failure
        (setf (plist-get state :status) (if (plist-get state :loaded) 'stale 'error)
              (plist-get state :diagnostics) (list failure))
      (let ((seen (make-hash-table :test #'equal)) unique)
        (dolist (session items)
          (unless (equal (ashub-source-key (ashub-session-source session)) key)
            (error "Adapter returned a session from another source"))
          (unless (gethash (ashub-session-key session) seen)
            (puthash (ashub-session-key session) t seen) (push session unique)))
        (when (seq-some (lambda (note) (eq (ashub-diagnostic-kind note) 'read)) diagnostics)
          (dolist (session old)
            (unless (gethash (ashub-session-key session) seen)
              (push (ashub-session-key session) (plist-get state :stale-keys))
              (push session unique))))
        (setf (plist-get state :items) (nreverse unique)
              (plist-get state :loaded) t
              (plist-get state :status) (cond ((null diagnostics) 'ok)
                                               ((seq-some (lambda (note) (eq (ashub-diagnostic-kind note) 'read)) diagnostics) 'partial)
                                               (t 'metadata))
              (plist-get state :diagnostics) diagnostics)))
    (puthash key state ashub--states)
    (ashub--render)))

(defun ashub-refresh ()
  "Asynchronously refresh all configured sources without resuming anything."
  (interactive)
  (let ((sources (ashub-configured-sources)) (old ashub--states)
        (buffer (current-buffer)))
    (ashub--cancel-scans)
    (setq ashub--states (make-hash-table :test #'equal))
    (dolist (source sources)
      (let* ((key (ashub-source-key source))
             (state (copy-sequence (and old (gethash key old)))))
        (setf (plist-get state :source) source (plist-get state :status) 'loading
              (plist-get state :diagnostics) nil (plist-get state :cancel) nil)
        (puthash key state ashub--states)))
    (ashub--render)
    (let ((generation ashub--generation))
      (dolist (source sources)
        (let* ((key (ashub-source-key source))
               (cancel
                (ashub-scan-source
                 source
                 (lambda (items diagnostics)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (when (= generation ashub--generation)
                         (condition-case err
                             (ashub--accept-source key items diagnostics nil)
                           (error (ashub--accept-source key nil nil (error-message-string err))))))))
                 (lambda (error)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (when (= generation ashub--generation)
                         (ashub--accept-source key nil nil error))))))))
          (when (eq (plist-get (gethash key ashub--states) :status) 'loading)
            (setf (plist-get (gethash key ashub--states) :cancel) cancel)))))))

(defun ashub--session-at-point ()
  "Return current row's session, or signal a helpful error."
  (or (get-text-property (point) 'ashub-session) (user-error "请先选择一条会话")))

(defun ashub-new-session ()
  "Choose an agent (default Pi), then a project, and create a new session."
  (interactive)
  (let* ((choice (completing-read "新建 Agent（默认 pi）：" '("pi" "claude" "codex" "dsh" "hermes") nil t nil nil "pi"))
         (agent (if (string-empty-p (string-trim choice)) 'pi (intern choice)))
         (session (get-text-property (point) 'ashub-session))
         (initial (or (and session (ashub--local-directory-p (ashub-session-cwd session))
                           (ashub-session-cwd session)) default-directory))
         (directory (read-directory-name (format "%s 项目目录：" agent) initial nil t)))
    (ashub-create-session agent directory)))

(defun ashub-open ()
  "Resume the exact session at point, through its configured client."
  (interactive) (ashub-open-session (ashub--session-at-point)))

(defun ashub--move-entry (direction)
  "Move DIRECTION lines at a time to another group or session entry."
  (let ((origin (point)) (key (get-text-property (point) 'ashub-key)) found)
    (while (and (not found) (zerop (forward-line direction)))
      (let ((next (get-text-property (point) 'ashub-key)))
        (when (and next (not (equal next key))) (setq found t))))
    (unless found (goto-char origin))
    found))

(defun ashub-next-entry (&optional count)
  "Move COUNT entries forward, skipping help and expanded previews."
  (interactive "p")
  (let ((count (or count 1)))
    (dotimes (_ (abs count)) (ashub--move-entry (if (< count 0) -1 1)))))

(defun ashub-previous-entry (&optional count)
  "Move COUNT entries backward, skipping help and expanded previews."
  (interactive "p")
  (ashub-next-entry (- (or count 1))))

(defun ashub-jump-agent (agent)
  "Filter to AGENT and reveal its first matching session, without scanning.
Keep the current project and search filters.  Never restore a session."
  (interactive (list (intern (completing-read "Agent：" '("claude" "codex" "pi" "dsh" "hermes") nil t))))
  (setq ashub--agent-filter agent)
  (let ((first (car (ashub--visible-sessions))))
    (when first (remhash (ashub--group-name first) ashub--collapsed))
    (ashub--render)
    (goto-char (point-min))
    (if first
        (when-let* ((match (text-property-search-forward 'ashub-key (ashub-session-key first) #'equal)))
          (goto-char (prop-match-beginning match)))
      (message "没有符合当前条件的 %s 会话；C 清除过滤，! 查看诊断" agent))))

(defun ashub-jump-claude ()
  "Filter and jump to Claude sessions."
  (interactive) (ashub-jump-agent 'claude))

(defun ashub-jump-codex ()
  "Filter and jump to Codex sessions."
  (interactive) (ashub-jump-agent 'codex))

(defun ashub-jump-pi ()
  "Filter and jump to Pi sessions."
  (interactive) (ashub-jump-agent 'pi))

(defun ashub-jump-dsh ()
  "Filter and jump to DSH sessions."
  (interactive) (ashub-jump-agent 'dsh))

(defun ashub-jump-hermes ()
  "Filter and jump to Hermes sessions."
  (interactive) (ashub-jump-agent 'hermes))

(defun ashub-toggle-group ()
  "Collapse or expand point's group."
  (interactive)
  (let ((name (or (get-text-property (point) 'ashub-group)
                  (ashub--group-name (ashub--session-at-point)))))
    (puthash name (not (gethash name ashub--collapsed)) ashub--collapsed)
    (ashub--render)))

(defun ashub-change-grouping ()
  "Toggle agent/project grouping while retaining filters."
  (interactive)
  (setq ashub--grouping (if (eq ashub--grouping 'agent) 'project 'agent))
  (clrhash ashub--collapsed) (ashub--render))

(defun ashub-filter-agent ()
  "Set or clear agent filter with completion."
  (interactive)
  (let ((choice (completing-read "Agent：" '("全部" "claude" "codex" "pi" "dsh" "hermes") nil t)))
    (setq ashub--agent-filter
          (unless (or (string-empty-p (string-trim choice)) (equal choice "全部"))
            (intern choice))))
  (ashub--render))

(defun ashub-filter-project ()
  "Set a literal project path filter, with history-based completion."
  (interactive)
  (let ((choice (completing-read
                 "项目路径（可输入片段）："
                 (cons "全部" (delete-dups (delq nil (mapcar #'ashub-session-cwd (ashub--all-sessions)))))
                 nil nil nil nil ashub--project-filter)))
    (setq ashub--project-filter (unless (or (equal choice "全部") (string-empty-p choice)) choice)))
  (ashub--render))

(defun ashub-search ()
  "Live literal search of agent, full ID, cwd and displayed message/preview.
Cancel restores the previous search.  No new scan or restore is triggered."
  (interactive)
  (let ((hub (current-buffer)) (old ashub--query) accepted)
    (unwind-protect
        (progn
          (minibuffer-with-setup-hook
              (lambda ()
                (add-hook 'post-command-hook
                          (lambda ()
                            (let ((query (minibuffer-contents-no-properties)))
                              (when (buffer-live-p hub)
                                (with-current-buffer hub (setq ashub--query query) (ashub--render)))))
                          nil t))
            (setq ashub--query (read-from-minibuffer "搜索：" old)))
          (setq accepted t))
      (unless accepted (setq ashub--query old))
      (ashub--render))))

(defun ashub-clear-filters ()
  "Clear search/agent/project filters without reading history again."
  (interactive)
  (setq ashub--query "" ashub--agent-filter nil ashub--project-filter nil)
  (ashub--render))

(defun ashub-toggle-preview ()
  "Toggle the selected message/preview/title, preserving its origin label."
  (interactive)
  (let ((key (ashub-session-key (ashub--session-at-point))))
    (puthash key (not (gethash key ashub--expanded)) ashub--expanded)
    (ashub--render)))

(defun ashub-details ()
  "Display full identity and known metadata, not a complete transcript."
  (interactive)
  (let* ((session (ashub--session-at-point)) (stale (ashub--stale-p session)))
    (with-help-window "*ashub details*"
      (princ (format "Agent: %s\nSession ID: %s\nSource: %s\nStorage path: %s\nProject: %s\n"
                     (ashub-session-agent session) (ashub-session-id session)
                     (ashub--source-label (ashub-session-source session))
                     (or (ashub-session-path session) "unknown")
                     (or (ashub-session-cwd session) "unknown")))
      (princ (format "Storage root: %s\nProfile label: %S\n"
                     (plist-get (ashub-session-source session) :root)
                     (plist-get (ashub-session-source session) :profile)))
      (princ (format "Origin: %S\nInteraction time: %S\nTime source: %S\nInternal: %S\nEmpty: %S\nArchived: %S\nData: %s\n"
                     (ashub-session-origin session) (ashub-session-last-active session)
                     (ashub-session-time-source session) (ashub-session-internal session)
                     (ashub-session-empty session) (ashub-session-archived session)
                     (if stale "stale; refresh failed" "see source status")))
      (when (ashub-session-title session)
        (princ (format "Title (not a raw first message): %s\n" (ashub-session-title session))))
      (princ (format "\nFirst user message:\n%s\n"
                     (or (ashub-session-first-message session) "[unknown]")))
      (when (and (not (ashub-session-first-message session))
                 (plist-get (ashub-session-metadata session) :prompt-preview))
        (princ (format "\nMessage preview (turnOutline; may be truncated):\n%s\n"
                       (plist-get (ashub-session-metadata session) :prompt-preview))))
      (princ (format "\nDisplayed date source: %S\n" (ashub-session-display-time-source session)))
      (dolist (field '((:updated-at . "Source updated at") (:created-at . "Source created at")))
        (when-let* ((seconds (plist-get (ashub-session-metadata session) (car field))))
          (princ (format "%s (not interaction time): %s\n" (cdr field)
                         (format-time-string "%Y-%m-%d %H:%M:%S" (seconds-to-time seconds)))))))))

(defun ashub--delete-file-for-session (session)
  "Return SESSION's validated local history file for permanent deletion."
  (unless (and (memq (ashub-session-agent session) '(claude pi))
               (not (plist-get (ashub-session-source session) :scan-function))
               (not (ashub--stale-p session)))
    (user-error "仅支持已刷新成功的内置 Claude/Pi 来源；当前会话不可删除"))
  (let* ((root (file-name-as-directory
                (file-truename (ashub--root (plist-get (ashub-session-source session) :root)))))
         (path (ashub-session-path session)))
    (unless (and (stringp path) (not (file-remote-p path))
                 (file-exists-p path) (file-regular-p path) (not (file-symlink-p path)))
      (user-error "会话文件不存在、不是普通文件或为符号链接：%s" (or path "unknown")))
    (let ((true-path (file-truename path)))
      (unless (and (file-in-directory-p true-path root)
                   (if (eq (ashub-session-agent session) 'claude)
                       (and (equal (file-name-extension path) "jsonl")
                            (equal (file-name-base path) (ashub-session-id session)))
                     t))
        (user-error "拒绝删除位于存储目录之外或无法匹配会话 ID 的文件：%s" path))
      true-path)))

(defun ashub-mark-delete ()
  "Mark or unmark the selected Claude/Pi session for deletion."
  (interactive)
  (let* ((session (ashub--session-at-point)) (key (ashub-session-key session)))
    (if (gethash key ashub--delete-marks)
        (progn (remhash key ashub--delete-marks) (message "已取消删除标记"))
      (ashub--delete-file-for-session session)
      (puthash key t ashub--delete-marks)
      (ashub-next-entry)
      (message "已标记删除；按 x 确认执行"))
    (ashub--render)))

(defun ashub-execute-deletions ()
  "Permanently delete marked Claude/Pi session files after confirmation."
  (interactive)
  (let (marked files)
    (dolist (session (ashub--all-sessions))
      (when (gethash (ashub-session-key session) ashub--delete-marks)
        (push session marked)
        (push (cons session (ashub--delete-file-for-session session)) files)))
    (unless marked (user-error "没有标记待删除的会话"))
    (unless (yes-or-no-p (format "永久删除 %d 个 Claude/Pi 会话文件？" (length marked)))
      (user-error "已取消删除"))
    (dolist (entry (nreverse files))
      (let* ((session (car entry)) (path (cdr entry))
             (key (ashub-session-key session))
             (source-key (ashub-source-key (ashub-session-source session)))
             (state (gethash source-key ashub--states)))
        (delete-file path)
        (setf (plist-get state :items)
              (seq-remove (lambda (item) (equal (ashub-session-key item) key))
                          (plist-get state :items)))
        (puthash source-key state ashub--states)
        (remhash key ashub--delete-marks)))
    (ashub--render)
    (message "已永久删除 %d 个会话文件" (length marked))))

(defun ashub-copy-id ()
  "Copy the full selected session ID to the kill ring and system clipboard."
  (interactive)
  (let ((id (ashub-session-id (ashub--session-at-point))))
    (kill-new id)
    (when (fboundp 'gui-set-selection)
      (gui-set-selection 'CLIPBOARD id))
    (message "已复制完整 session ID: %s" id)))

(defun ashub-copy-project ()
  "Copy the selected session's recorded project directory."
  (interactive)
  (let ((cwd (ashub-session-cwd (ashub--session-at-point))))
    (unless cwd (user-error "该会话未记录项目目录")) (kill-new cwd) (message "已复制项目路径")))

(defun ashub-diagnostics ()
  "Separate source failures, read issues and missing metadata."
  (interactive)
  (let ((states ashub--states) (visible (length (ashub--visible-sessions)))
        (total (length (ashub--all-sessions))))
    (with-help-window "*ashub diagnostics*"
      (princ (format "显示 %d/已载入 %d；过滤/隐藏 %d。\n" visible total (- total visible)))
      (princ "字段缺失：会话已载入，但部分原始字段不可用；预览/标题会单独标注。\n")
      (princ "读取异常：部分文件或消息未完整载入。来源失败：扫描失败，旧数据可能保留。\n")
      (princ "过滤/隐藏包括当前搜索条件，以及默认排除的内部、空和归档会话。\n\n")
      (maphash (lambda (_key state)
                 (princ (format "%s\nStatus: %s; retained records: %d\n"
                                (ashub--source-label (plist-get state :source))
                                (plist-get state :status) (length (plist-get state :items))))
                 (dolist (note (plist-get state :diagnostics))
                   (princ (format "  [%s] %s\n"
                                  (cond ((memq (plist-get state :status) '(error stale)) "来源失败")
                                        ((eq (ashub-diagnostic-kind note) 'metadata) "字段缺失")
                                        (t "读取异常"))
                                  (ashub-diagnostic-text note))))
                 (princ "\n")) states))))

(defun ashub-quit ()
  "Cancel scans and restore this frame's previous layout, without stopping chats."
  (interactive)
  (ashub--cancel-scans)
  (let ((configuration (frame-parameter nil 'ashub-window-configuration)))
    (set-frame-parameter nil 'ashub-window-configuration nil)
    (if (window-configuration-p configuration)
        (set-window-configuration configuration)
      (quit-window))))

(defvar ashub-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (entry '(("N" . ashub-new-session) ("RET" . ashub-open) ("/" . ashub-search) ("a" . ashub-filter-agent)
                     ("n" . ashub-next-entry) ("p" . ashub-previous-entry)
                     ("o" . ashub-filter-project) ("c" . ashub-change-grouping)
                     ("1" . ashub-jump-claude) ("2" . ashub-jump-codex) ("3" . ashub-jump-pi)
                     ("4" . ashub-jump-dsh) ("5" . ashub-jump-hermes)
                     ("TAB" . ashub-toggle-group) ("g" . ashub-refresh)
                     ("e" . ashub-toggle-preview) ("i" . ashub-details)
                     ("d" . ashub-mark-delete) ("x" . ashub-execute-deletions)
                     ("w" . ashub-copy-id) ("W" . ashub-copy-project)
                     ("!" . ashub-diagnostics) ("C" . ashub-clear-filters)
                     ("C-c C-k" . ashub-clear-filters)
                     ("q" . ashub-quit)))
      (define-key map (kbd (car entry)) (cdr entry)))
    map))

(define-derived-mode ashub-mode special-mode "ashub"
  "Browse historical agent sessions, without taking over external processes."
  (setq-local truncate-lines t)
  (setq ashub--states (make-hash-table :test #'equal)
        ashub--collapsed (make-hash-table :test #'equal)
        ashub--expanded (make-hash-table :test #'equal)
        ashub--delete-marks (make-hash-table :test #'equal)
        ashub--grouping ashub-group-by)
  (add-hook 'kill-buffer-hook #'ashub--cancel-scans nil t))

;;;###autoload
(defun ashub ()
  "Open the Hub in the whole current frame and read history asynchronously.
The q command restores this frame's previous window layout."
  (interactive)
  (let ((buffer (get-buffer-create "*ashub*")) (frame (selected-frame)))
    (unless (and (get-buffer-window buffer frame)
                 (frame-parameter frame 'ashub-window-configuration))
      (set-frame-parameter frame 'ashub-window-configuration (current-window-configuration)))
    (switch-to-buffer buffer)
    (delete-other-windows)
    (unless (derived-mode-p 'ashub-mode) (ashub-mode))
    (ashub-refresh)))

(provide 'ashub)
;; After provide: ashub-reference uses the Hub lazily, without a load cycle.
(require 'ashub-reference)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; ashub.el ends here
