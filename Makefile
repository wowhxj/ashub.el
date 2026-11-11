EMACS ?= emacs
PYTHON ?= python3
ELISP = ashub-core.el ashub-sources.el ashub-tmux.el ashub-native.el ashub-open.el ashub-reference.el ashub-summary.el ashub-details.el ashub-search.el ashub.el
DEV_ELISP = dev/readonly-init.el

.PHONY: check structure compile test package-check clean

check: structure compile test

structure:
	$(EMACS) -Q --batch --eval '(dolist (file (quote ($(foreach f,$(ELISP) $(DEV_ELISP) test/ashub-test.el test/ashub-summary-test.el test/ashub-details-test.el test/ashub-search-test.el,"$(f)")))) (find-file file) (check-parens))'

compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(ELISP)

test:
	$(PYTHON) -B -m unittest discover -s test -p 'test_*.py' -v
	$(EMACS) -Q --batch -L . --eval '(setq load-prefer-newer t)' -l test/ashub-test.el -l test/ashub-summary-test.el -l test/ashub-details-test.el -l test/ashub-search-test.el -l test/tmux-test.el -l test/runtime-inventory-test.el -l test/native-runtime-test.el -l test/claude-native-test.el -f ert-run-tests-batch-and-exit

# Offline relocated build; retains staging artifacts and never installs packages.
package-check:
	$(PYTHON) -B test/package-stage.py

clean:
	rm -f $(ELISP:.el=.elc) $(ELISP:%=%~) test/ashub-test.el~ ashub-autoloads.el
	rm -rf __pycache__ test/__pycache__
