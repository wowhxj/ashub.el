#!/usr/bin/env bash
# One-shot reproducible offline regression gate; NOT a development loop or full acceptance.
# Only disposable fixture Hosts/sessions are created. No model prompts or installs.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
DSH=${EMACS_DSH_REPO:-$(dirname "$ROOT")/emacs-dsh}
PI=${EMACS_PI_REPO:-$(dirname "$ROOT")/emacs-pi}
MD=${EMACS_TEST_MARKDOWN:-/Users/randolph/.emacs.d.default/elpa/markdown-mode-20261022.55}
WS=${EMACS_TEST_WEBSOCKET:-/Users/randolph/.emacs.d.default/elpa/websocket-20260301.157}
GHOSTEL=${EMACS_TEST_GHOSTEL:-/Users/randolph/.emacs.d.default/elpa/ghostel-20261019.1232}
EMACS=${EMACS:-emacs}
OUT=$(mktemp -d /tmp/ashub-passive-verification.XXXXXX)
RESULTS="$OUT/RESULTS.txt"
for directory in "$ROOT" "$DSH" "$PI" "$MD" "$WS" "$GHOSTEL"; do
  test -d "$directory" || { printf 'Missing prerequisite: %s\n' "$directory"; exit 1; }
done
printf 'ARTIFACTS=%s\n' "$OUT"
{
  printf 'One-shot offline native safety verification, not final lifecycle acceptance\n'
  printf 'ASHUB=%s\nDSH=%s\nPI=%s\nMARKDOWN=%s\nWEBSOCKET=%s\nGHOSTEL=%s\n' "$ROOT" "$DSH" "$PI" "$MD" "$WS" "$GHOSTEL"
  date -u
  node --version
  "$EMACS" --version
} > "$RESULTS"
run() {
  local name=$1
  shift
  printf 'cwd=%q command=' "$PWD" >> "$RESULTS"
  printf '%q ' "$@" >> "$RESULTS"
  printf '\n' >> "$RESULTS"
  if "$@" > "$OUT/$name.log" 2>&1; then
    printf 'PASS %s\n' "$name" | tee -a "$RESULTS"
    tail -n 10 "$OUT/$name.log"
  else
    local status=$?
    printf 'FAIL %s exit=%s\n' "$name" "$status" | tee -a "$RESULTS"
    tail -n 45 "$OUT/$name.log"
    exit "$status"
  fi
}
cd "$ROOT"
# Compile before tests (never concurrently with readers of the same .elc files).
run compile "$EMACS" --batch -Q -L . -L "$DSH" -L "$MD" -L "$WS" \
  --eval '(setq load-prefer-newer t)' --eval '(require (quote bytecomp))' \
  --eval '(let ((byte-compile-error-on-warn t)) (dolist (file (list "ashub-native.el" "ashub-summary.el" "ashub-open.el" (expand-file-name "emacs-dsh.el" (file-name-directory (locate-library "emacs-dsh"))))) (unless (byte-compile-file file) (error "Compilation failed: %s" file))))'
run hub-python python3 -B -m unittest discover -s test -p 'test_*.py' -v
run terminal-owner env ASHUB_TMUX_NATIVE=1 python3 -B test/terminal-owner-test.py
run package-stage python3 -B test/package-stage.py
run hub-ert "$EMACS" --batch -Q -L . -L "$MD" -L "$WS" --eval '(setq load-prefer-newer t)' \
  -l test/ashub-test.el -l test/ashub-summary-test.el -l test/ashub-details-test.el -l test/ashub-search-test.el -l test/tmux-test.el -l test/runtime-inventory-test.el -l test/native-runtime-test.el -f ert-run-tests-batch-and-exit
run hub-pi-public "$EMACS" --batch -Q -L . -L "$PI" -L "$MD" -L "$WS" --eval '(setq load-prefer-newer t)' \
  -l test/native-runtime-integration.el -f ert-run-tests-batch-and-exit
run hub-pi-missing "$EMACS" --batch -Q -L . -L "$PI" -L "$MD" -L "$WS" --eval '(setq load-prefer-newer t)' \
  -l test/pi-attach-missing-integration.el -f ert-run-tests-batch-and-exit
run hub-dsh-public env ASHUB_DSH_REAL=1 "$EMACS" --batch -Q -L . -L "$DSH" -L "$MD" -L "$WS" --eval '(setq load-prefer-newer t)' \
  -l test/native-dsh-integration.el -f ert-run-tests-batch-and-exit
run ghostel env ASHUB_TMUX_GHOSTEL=1 "$EMACS" --batch -Q -L . -L "$GHOSTEL" --eval '(setq load-prefer-newer t)' \
  -l test/tmux-test.el -f ert-run-tests-batch-and-exit
run ashub-diff git diff --check
cd "$PI"
run pi-compile "$EMACS" --batch -Q -L . -L "$MD" --eval '(setq load-prefer-newer t)' --eval '(require (quote bytecomp))' \
  --eval '(let ((byte-compile-error-on-warn t)) (dolist (file (quote ("emacs-pi-runtime.el" "emacs-pi-rpc.el" "emacs-pi-session.el" "emacs-pi.el"))) (unless (byte-compile-file file) (error "Compilation failed: %s" file))))'
run pi-syntax node --check emacs-pi-bridge.mjs
run pi-node env PI_BRIDGE_REAL=1 EMACS_PI_TEST_MARKDOWN="$MD" node --test test/bridge.test.mjs test/native-process.test.mjs
run pi-ert "$EMACS" --batch -Q -L . -L "$MD" --eval '(setq load-prefer-newer t)' \
  -l test/emacs-pi-test.el -l test/public-api-test.el -l test/history-cache-test.el -l test/persistent-test.el -f ert-run-tests-batch-and-exit
run pi-diff git diff --check
cd "$DSH"
run dsh-ert "$EMACS" --batch -Q -L . -L "$ROOT" -L "$MD" -L "$WS" --eval '(setq load-prefer-newer t)' \
  -l tests.el -l public-api-tests.el -l ashub-compat-tests.el -l test/persistent-test.el -f ert-run-tests-batch-and-exit
run dsh-node env DSH_HOST_NATIVE=1 DSH_HOST_REAL=1 EMACS_DSH_TEST_MARKDOWN="$MD" EMACS_DSH_TEST_WEBSOCKET="$WS" \
  node --test test/host-supervisor.test.mjs test/native-host.test.mjs test/real-host.test.mjs
run dsh-diff git diff --check
printf 'One-shot gate passed. Retained logs: %s\n' "$OUT" | tee -a "$RESULTS"
