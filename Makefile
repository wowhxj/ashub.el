EMACS ?= emacs
PYTHON ?= python3
ELISP = ashub-core.el ashub-sources.el ashub-open.el ashub.el
DEV_ELISP = dev/readonly-init.el

.PHONY: check structure compile test clean

check: structure compile test

structure:
	$(EMACS) -Q --batch --eval '(dolist (file (quote ($(foreach f,$(ELISP) $(DEV_ELISP) test/ashub-test.el,"$(f)")))) (find-file file) (check-parens))'

compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(ELISP)

test:
	$(PYTHON) -B -m unittest discover -s test -p 'test_*.py' -v
	$(EMACS) -Q --batch -L . --eval '(setq load-prefer-newer t)' -l test/ashub-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -f $(ELISP:.el=.elc) $(ELISP:%=%~) test/ashub-test.el~ ashub-autoloads.el
	rm -rf __pycache__ test/__pycache__
