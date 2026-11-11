#!/usr/bin/env python3
"""Offline relocatable package-resource check. Never installs or invokes a model.

Copies only product Lisp/resources, generates autoloads/bytecode in a temporary
build tree, relocates it, then loads and exercises the relocated packages in a
fresh Emacs with disposable HOME. Retains the complete tree/logs for reruns.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

HUB = Path(__file__).resolve().parents[1]
PI = Path(os.environ.get('EMACS_PI_REPO', HUB.parent / 'emacs-pi')).resolve()
DSH = Path(os.environ.get('EMACS_DSH_REPO', HUB.parent / 'emacs-dsh')).resolve()
MD = Path(os.environ.get('EMACS_TEST_MARKDOWN', '/Users/randolph/.emacs.d.default/elpa/markdown-mode-20261022.55'))
WS = Path(os.environ.get('EMACS_TEST_WEBSOCKET', '/Users/randolph/.emacs.d.default/elpa/websocket-20260301.157'))
EMACS = os.environ.get('EMACS', 'emacs')
OUT = Path(tempfile.mkdtemp(prefix='as-stage-', dir='/tmp')).resolve()
BUILD = OUT / 'build'
INSTALLED = OUT / 'installed'
HOME = OUT / 'home'
HOME.mkdir()
print(f'ARTIFACTS={OUT}', flush=True)
manifest = []
packages = [(HUB, 'ashub', 'ashub*.el', ['ashub-scan.py', 'ashub-summary-read.py', 'ashub-terminal.py']),
            (PI, 'emacs-pi', 'emacs-pi*.el', ['emacs-pi-bridge.mjs']),
            (DSH, 'emacs-dsh', 'emacs-dsh*.el', ['emacs-dsh-host.mjs'])]
for repo, name, pattern, resources in packages:
    target = BUILD / name
    target.mkdir(parents=True)
    files = [p for p in repo.glob(pattern) if not p.name.endswith('-autoloads.el')]
    files += [repo / f for f in resources]
    for source in sorted(files):
        if not source.is_file() or source.is_symlink():
            raise RuntimeError(f'Missing/unsafe package resource: {source}')
        shutil.copy2(source, target / source.name)
        manifest.append({'package': name, 'file': source.name, 'sha256': hashlib.sha256(source.read_bytes()).hexdigest()})
(OUT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
env = {k: os.environ[k] for k in ('PATH', 'LANG', 'TERM', 'TMPDIR') if k in os.environ}
env.update(HOME=str(HOME), XDG_CACHE_HOME=str(HOME / '.cache'), PI_CODING_AGENT_DIR=str(HOME / 'pi'),
           DSH_HOME=str(HOME / 'dsh'), STAGE_ROOT=str(OUT), STAGE_PI_FAKE=str(PI / 'test/fake-pi.py'),
           STAGE_DSH_FAKE=str(DSH / 'test/fake-host.mjs'), STAGE_NODE=shutil.which('node') or '')


def run(name, command):
    with (OUT / f'{name}.log').open('w') as log:
        result = subprocess.run(command, cwd=OUT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=120)
    if result.returncode:
        print((OUT / f'{name}.log').read_text()[-10000:])
        raise RuntimeError(f'{name} failed; retained artifacts: {OUT}')
    print(f'PASS {name}', flush=True)


lisp = ['--batch', '-Q', '--eval', '(setq load-prefer-newer t)', '--eval', '(require (quote bytecomp))']
for directory in [BUILD / name for _, name, _, _ in packages] + [MD, WS]:
    lisp += ['-L', str(directory)]
# Generate relocatable relative autoload entries and compile only staged copies.
expr = f"""(progn
(require 'loaddefs-gen)
(dolist (name '("ashub" "emacs-pi" "emacs-dsh"))
  (let* ((dir (expand-file-name name {json.dumps(str(BUILD))}))
         (auto (expand-file-name (concat name "-autoloads.el") dir)))
    (loaddefs-generate dir auto)))
(let ((byte-compile-error-on-warn t))
  (dolist (name '("ashub" "emacs-pi" "emacs-dsh"))
    (dolist (file (directory-files (expand-file-name name {json.dumps(str(BUILD))}) t))
      (when (string-suffix-p ".el" file)
        (unless (byte-compile-file file) (error "Stage compile failed: %s" file)))))))"""
run('build', [EMACS] + lisp + ['--eval', expr])
for item in manifest:
    if item['file'].endswith('.el') and not (BUILD / item['package'] / item['file']).with_suffix('.elc').is_file():
        raise RuntimeError('Missing compiled artifact: ' + item['file'])
BUILD.rename(INSTALLED)
for name in ('ashub', 'emacs-pi', 'emacs-dsh'):
    run(f'node-{name}', ['node', '--version'] if name == 'ashub' else ['node', '--check', str(INSTALLED / name / ('emacs-pi-bridge.mjs' if name == 'emacs-pi' else 'emacs-dsh-host.mjs'))])
run('python-resources', ['python3', '-B', '-c', 'import ast,pathlib; [ast.parse(p.read_text()) for p in pathlib.Path("' + str(INSTALLED / 'ashub') + '").glob("*.py")]'])
loads = []
for name in ('ashub', 'emacs-pi', 'emacs-dsh'):
    loads += ['-L', str(INSTALLED / name)]
run('relocated-lifecycle', [EMACS, '--batch', '-Q'] + loads + ['-L', str(MD), '-L', str(WS), '-l', str(HUB / 'test/package-stage.el')])
summary = {'status': 'passed', 'root': str(OUT), 'manifestFiles': len(manifest), 'modelsInvoked': 0,
           'scope': 'relocated source/bytecode/autoload/resource and controlled lifecycle; not user installation or live model acceptance'}
(OUT / 'RESULTS.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
