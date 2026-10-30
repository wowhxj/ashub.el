;;; ashub-details-test.el --- Details presentation regression tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'ashub)

(defmacro ashub-details-test-with-view (conversation width &rest body)
  "Render CONVERSATION at WIDTH, then run BODY without reading history/models."
  (declare (indent 2) (debug t))
  `(with-temp-buffer
     (ashub-details-mode)
     (setq ashub-details--session
           (ashub-session-create :agent 'pi :id "example-session-123"
                                 :source (list :agent 'pi :root temporary-file-directory)
                                 :cwd temporary-file-directory :path "/history/example.jsonl"
                                 :last-active 1793267135 :time-source 'message
                                 :first-message "原始首句" :metadata '(:reference (:last "原始末句")))
           ashub-details--conversation ,conversation
           ashub-details--turns (ashub-details--parse ashub-details--conversation))
     (cl-letf (((symbol-function 'ashub-summary-entry)
                (lambda (_) '(:summary "完成会话展示优化，测试已通过。" :model "test-model" :generated-at 1793267135)))
               ((symbol-function 'ashub--summary-status) (lambda (_) "已生成"))
               ((symbol-function 'ashub-reference-markdown)
                (lambda (&rest _) (ert-fail "Rendering must not read history")))
               ((symbol-function 'gptel-request)
                (lambda (&rest _) (ert-fail "Rendering must not call models"))))
       (ashub-details--render ,width)
       ,@body)))

(ert-deftest ashub-details-parses-markdown-roles-without-code-fence-confusion ()
  (let* ((text "## User · 2026-10-30\n请检查这个例子：\n```text\n## Assistant\nUser: this is code\n```\n\n## Assistant\n已检查，仍待测试。")
         (turns (ashub-details--parse text)))
    (should (equal (mapcar (lambda (turn) (plist-get turn :role)) turns) '(user assistant)))
    (should (string-match-p "## Assistant\nUser: this is code" (plist-get (car turns) :text)))
    (should (equal (plist-get (cadr turns) :text) "已检查，仍待测试。"))))

(ert-deftest ashub-details-parses-native-pi-and-summary-labels ()
  (let ((turns (ashub-details--parse "User: question\n\nPi: answer\n\nSummary: older context\n\nUser: next")))
    (should (equal (mapcar (lambda (turn) (plist-get turn :role)) turns)
                   '(user assistant assistant user)))
    (should (equal (plist-get (nth 2 turns) :label) "Summary"))
    (should (equal (plist-get (car turns) :text) "question"))))

(ert-deftest ashub-details-code-fence-language-does-not-close-a-fence ()
  (let ((turns (ashub-details--parse
                "## User\n````text\n```python\n## Assistant\ncode\n````\n\n## Assistant\nreal answer")))
    (should (= (length turns) 2))
    (should (string-match-p "## Assistant\ncode" (plist-get (car turns) :text)))))

(ert-deftest ashub-details-empty-and-failed-reads-do-not-invent-user-turns ()
  (should-not (ashub-details--parse "\n\n"))
  (let ((turns (ashub-details--parse "[读取对话失败：示例错误]")))
    (should (eq (plist-get (car turns) :role) 'notice))
    (should (equal (plist-get (car turns) :text) "[读取对话失败：示例错误]"))))

(ert-deftest ashub-details-metadata-is-collapsed-but-complete-and-toggleable ()
  (ashub-details-test-with-view "## User\n问题\n\n## Assistant\n答案" 120
                                (goto-char (point-min))
                                (search-forward "Session ID:")
                                (should (invisible-p (1- (point))))
                                (should (string-match-p "example-session-123" (buffer-string)))
                                (should (string-match-p "Storage path: /history/example.jsonl" (buffer-string)))
                                (should (string-match-p "First user message:\n原始首句" (buffer-string)))
                                (should (string-match-p "Last user message:\n原始末句" (buffer-string)))
                                (ashub-details-toggle-metadata)
                                (should-not (invisible-p (1- (point))))
                                (should ashub-details--metadata-expanded)
                                (should-not (buffer-modified-p))
                                (should (string-prefix-p "▾" (button-get ashub-details--metadata-button 'display)))
                                (ashub-details-toggle-metadata)
                                (should (invisible-p (1- (point))))))

(ert-deftest ashub-details-visible-introduction-is-compact ()
  (ashub-details-test-with-view "## User\n问题\n\n## Assistant\n答案" 120
                                (let ((end (text-property-not-all (point-min) (point-max) 'ashub-turn-index nil)) (lines 0))
                                  (goto-char (point-min))
                                  (while (re-search-forward "\n" end t)
                                    (unless (invisible-p (1- (point))) (cl-incf lines)))
                                  (should (<= lines 9)))
                                (should (string-match-p "2026-" (buffer-string)))
                                (should (string-match-p "2 条消息" (buffer-string)))))

(ert-deftest ashub-details-user-right-agent-left-with-bounded-chat-rows ()
  (dolist (width '(40 80 155))
    (ashub-details-test-with-view
     (concat "## User\n" (make-string 220 ?中) "\n\n## Assistant\n"
             "已检查，下面是一个较长的英文标识：\n" (make-string 180 ?a)) width
     (let (left right)
       (goto-char (point-min))
       (while (not (eobp))
         (when (get-text-property (point) 'ashub-turn-index)
           (should (<= (string-width (buffer-substring-no-properties
                                      (line-beginning-position) (line-end-position))) width)))
         (forward-line 1))
       (goto-char (point-min))
       (let ((match (text-property-search-forward 'ashub-details-side 'left #'eq)))
         (should match)
         (goto-char (prop-match-beginning match))
         (setq left (current-column))
         (should (eq (plist-get (get-text-property (point) 'face) :inherit) 'ashub-details-assistant-face)))
       (goto-char (point-min))
       (let ((match (text-property-search-forward 'ashub-details-side 'right #'eq)))
         (should match)
         (goto-char (prop-match-beginning match))
         (setq right (current-column))
         (should (eq (plist-get (get-text-property (point) 'face) :inherit) 'ashub-details-user-face)))
       (should (= left 2))
       (should (> right left))))))

(ert-deftest ashub-details-copy-returns-original-text-not-chat-padding ()
  (let* ((body "第一行\n\n```elisp\n\t(message \"完整原文\")\n```\n连续标识abcdefghijklmnopqrstuvwxyz")
         (conversation (concat "## User\n" body "\n\n## Assistant\n收到"))
         (kill-ring nil) (interprogram-cut-function nil))
    (ashub-details-test-with-view conversation 40
                                  (let ((button (next-button (point-min))))
                                    (while (and button (not (button-get button 'ashub-original)))
                                      (setq button (next-button (button-end button))))
                                    (should button)
                                    (button-activate button)
                                    (should (equal (current-kill 0 t) body)))
                                  (ashub-details-copy-conversation)
                                  (should (equal (current-kill 0 t) conversation)))))

(ert-deftest ashub-details-reflow-preserves-raw-data-and-metadata-state ()
  (ashub-details-test-with-view "## User\n一个问题\n\n## Assistant\n一个答案" 120
                                (let ((original ashub-details--conversation))
                                  (ashub-details-toggle-metadata)
                                  (ashub-details--render 40)
                                  (should (= ashub-details--width 40))
                                  (should (equal ashub-details--conversation original))
                                  (should ashub-details--metadata-expanded)
                                  (should-not (overlay-get ashub-details--metadata-overlay 'invisible))
                                  (should (= (length ashub-details--turns) 2)))))

(ert-deftest ashub-details-hidden-metadata-opens-for-isearch ()
  (ashub-details-test-with-view "User: 问题" 80
                                (ashub-details--isearch-open ashub-details--metadata-overlay)
                                (should ashub-details--metadata-expanded)
                                (should-not (overlay-get ashub-details--metadata-overlay 'invisible))))

(ert-deftest ashub-details-refresh-and-fold-bindings-are-commands ()
  (should (commandp (lookup-key ashub-details-mode-map (kbd "g"))))
  (should (eq (lookup-key ashub-details-mode-map (kbd "m")) 'ashub-details-toggle-metadata))
  (should (eq (lookup-key ashub-details-mode-map (kbd "C-c C-w")) 'ashub-details-copy-conversation)))

(ert-deftest ashub-details-source-timestamps-stay-distinct-from-interactions ()
  (ashub-details-test-with-view "User: 问题" 120
                                (setf (ashub-session-last-active ashub-details--session) nil
                                      (ashub-session-time-source ashub-details--session) nil
                                      (ashub-session-metadata ashub-details--session) '(:updated-at 1793267135))
                                (ashub-details--render 120)
                                (goto-char (point-min))
                                (forward-line 1)
                                (should (looking-at "[0-9-]+ [0-9:]+\\*"))))

(ert-deftest ashub-details-long-single-line-wrap-preserves-all-readable-text ()
  (let* ((text (concat (make-string 20000 ?中) " token " (make-string 20000 ?x)))
         (rows (ashub-details--wrap-line text 79)))
    (should (equal (mapconcat #'identity rows "") text))
    (should (cl-every (lambda (row) (<= (string-width row) 79)) rows))))

(provide 'ashub-details-test)
;;; ashub-details-test.el ends here
