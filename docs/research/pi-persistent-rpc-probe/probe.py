#!/usr/bin/env python3
"""Isolated feasibility probe, NOT a production transport.
One client at a time. Bounded run, in-memory replay; no crash recovery.
No model prompts, no user sessions, no network services.
"""
import asyncio
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
SOCKET = ROOT / 'bridge.sock'

async def bridge():
    os.umask(0o077)
    env = dict(os.environ, PI_CODING_AGENT_DIR=str(ROOT / 'agent'))
    args = ['pi', '--mode', 'rpc', '--offline', '--no-extensions', '--no-mcp',
            '--no-skills', '--no-prompt-templates', '--no-tools',
            '--session', str(ROOT / 'session.jsonl'), '--session-dir', str(ROOT / 'sessions')]
    with (ROOT / 'pi-stderr.log').open('wb') as stderr:
        pi = await asyncio.create_subprocess_exec(*args, cwd=ROOT, env=env,
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=stderr,
                limit=8 * 1024 * 1024)
        records = []
        condition = asyncio.Condition()
        lease = asyncio.Lock()
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, stop.set)
        (ROOT / 'identity.json').write_text(json.dumps({'bridge_pid': os.getpid(), 'pi_pid': pi.pid}))

        async def drain():
            while line := await pi.stdout.readline():
                record = json.loads(line)
                with (ROOT / 'event-summary.jsonl').open('a') as journal:
                    journal.write(json.dumps({'seq': len(records) + 1,
                        'type': record.get('type'), 'id': record.get('id'),
                        'bytes': len(line)}) + '\n')
                async with condition:
                    records.append(record)
                    condition.notify_all()
            stop.set()

        async def handle(reader, writer):
            if lease.locked():
                writer.close()
                return
            async with lease:
                sender = None
                try:
                    hello = json.loads(await reader.readline())
                    cursor = hello['after']
                    assert isinstance(cursor, int) and 0 <= cursor <= len(records)

                    async def send_records():
                        nonlocal cursor
                        while True:
                            async with condition:
                                await condition.wait_for(lambda: len(records) > cursor)
                                batch = list(enumerate(records[cursor:], cursor + 1))
                            for seq, record in batch:
                                writer.write(json.dumps({'seq': seq, 'record': record}).encode() + b'\n')
                                await writer.drain()
                                cursor = seq
                    sender = asyncio.create_task(send_records())
                    while line := await reader.readline():
                        # For this isolated test only: transparent command forwarding.
                        json.loads(line)
                        pi.stdin.write(line)
                        await pi.stdin.drain()
                except (ConnectionError, asyncio.IncompleteReadError):
                    pass
                finally:
                    if sender:
                        sender.cancel()
                        await asyncio.gather(sender, return_exceptions=True)
                    writer.close()
                    try:
                        await writer.wait_closed()
                    except ConnectionError:
                        pass
        drain_task = asyncio.create_task(drain())
        server = await asyncio.start_unix_server(handle, path=str(SOCKET))
        try:
            await stop.wait()
        finally:
            server.close()
            await server.wait_closed()
            if pi.returncode is None:
                pi.stdin.close()
                try:
                    await asyncio.wait_for(pi.wait(), 5)
                except asyncio.TimeoutError:
                    pi.kill()
                    await pi.wait()
            drain_task.cancel()
            await asyncio.gather(drain_task, return_exceptions=True)
            SOCKET.unlink(missing_ok=True)


def command_for(label):
    command = "sleep 2; printf 'probe-%s-start\\n'; " % label
    command += "python3 -c \"import sys;sys.stdout.write('x'*1048576);sys.stdout.flush()\"; "
    command += "printf '\\nprobe-%s-done\\n'; printf done > '%s'" % (label, ROOT / (label + '.done'))
    return {'type': 'bash', 'id': 'bash-' + label, 'command': command}


def client(mode):
    sock = socket.socket(socket.AF_UNIX)
    sock.settimeout(15)
    sock.connect(str(SOCKET))
    stream = sock.makefile('rwb', buffering=0)
    cursor_path = ROOT / 'cursor.json'
    cursor = json.loads(cursor_path.read_text()) if cursor_path.exists() else 0
    stream.write(json.dumps({'after': cursor}).encode() + b'\n')
    seen = []
    def send(record):
        stream.write(json.dumps(record).encode() + b'\n')
    def read_until(predicate):
        nonlocal cursor
        while True:
            envelope = json.loads(stream.readline())
            assert envelope['seq'] == cursor + 1, (envelope['seq'], cursor)
            cursor = envelope['seq']
            seen.append(envelope['record'])
            if predicate(envelope['record']):
                return envelope['record']
    def request(kind, ident):
        send({'id': ident, 'type': kind})
        result = read_until(lambda r: r.get('type') == 'response' and r.get('id') == ident)
        assert result['success'], result
        return result['data']
    if mode.startswith('start-'):
        label = mode.removeprefix('start-')
        state = request('get_state', 'state-' + label)
        (ROOT / ('state-' + label + '.json')).write_text(json.dumps(state))
        # Delay gives the controller time to exit/kill this client before output.
        send(command_for(label))
        cursor_path.write_text(json.dumps(cursor))
        (ROOT / (label + '.sent')).write_text('sent')
        if label == 'crash':
            # Controller kills this process with SIGKILL; intentionally no reads.
            time.sleep(15)
    elif mode.startswith('resume-'):
        label = mode.removeprefix('resume-')
        response = read_until(lambda r: r.get('type') == 'response' and r.get('id') == 'bash-' + label)
        assert response['success'], response
        assert response['data']['exitCode'] == 0, response
        state = request('get_state', 'after-' + label)
        initial = json.loads((ROOT / ('state-' + label + '.json')).read_text())
        assert state['sessionId'] == initial['sessionId']
        assert state['sessionFile'] == initial['sessionFile']
        messages = request('get_messages', 'messages-' + label)
        assert ('probe-' + label + '-done') in json.dumps(messages)
        updates = [r for r in seen if r.get('type') == 'bash_execution_update']
        assert updates, 'No streamed events replayed'
        cursor_path.write_text(json.dumps(cursor))
        print(json.dumps({'case': label, 'session_id': state['sessionId'],
                          'replayed_updates': len(updates), 'records_read': len(seen),
                          'messages_contain_completion': True, 'cursor': cursor}))
    stream.close()
    sock.close()


def wait_file(path, process=None):
    deadline = time.monotonic() + 20
    while not path.exists():
        if process is not None and process.poll() is not None:
            raise RuntimeError('Process exited early: ' + str(process.returncode))
        if time.monotonic() >= deadline:
            raise TimeoutError(str(path))
        time.sleep(0.05)


def test():
    os.umask(0o077)
    (ROOT / 'agent').mkdir(exist_ok=True)
    for name in ('normal.sent', 'normal.done', 'crash.sent', 'crash.done', 'cursor.json', 'event-summary.jsonl'):
        (ROOT / name).unlink(missing_ok=True)
    # Clean synthetic session, no existing user history.
    (ROOT / 'session.jsonl').write_text(json.dumps({'type': 'session', 'version': 3,
        'id': 'ashub-persistent-rpc-probe', 'cwd': str(ROOT),
        'timestamp': '2026-11-10T00:00:00.000Z'}) + '\n')
    log = (ROOT / 'bridge.log').open('wb')
    owner = subprocess.Popen([sys.executable, __file__, 'bridge'], cwd=ROOT,
                              start_new_session=True, stdout=log, stderr=log)
    children = []
    try:
        wait_file(SOCKET, owner)
        identity = json.loads((ROOT / 'identity.json').read_text())
        assert identity['bridge_pid'] == owner.pid
        assert (SOCKET.stat().st_mode & 0o077) == 0
        for label in ('normal', 'crash'):
            if '--emacs' in sys.argv:
                (ROOT / 'start-command.json').write_text(json.dumps(command_for(label)))
                first = subprocess.Popen(['emacs', '--batch', '-Q', '-l', str(ROOT / 'client.el')],
                    cwd=ROOT, env=dict(os.environ, PROBE_ROOT=str(ROOT), PROBE_LABEL=label))
            else:
                first = subprocess.Popen([sys.executable, __file__, 'client', 'start-' + label], cwd=ROOT)
            children.append(first)
            wait_file(ROOT / (label + '.sent'), first)
            if label == 'crash':
                first.kill()
                assert first.wait(timeout=5) == -signal.SIGKILL
            else:
                assert first.wait(timeout=5) == 0
            assert not (ROOT / (label + '.done')).exists(), 'Client did not exit before work completed'
            wait_file(ROOT / (label + '.done'), owner)
            os.kill(identity['pi_pid'], 0)
            assert owner.poll() is None
            subprocess.run([sys.executable, __file__, 'client', 'resume-' + label],
                           cwd=ROOT, check=True, timeout=20)
        print(json.dumps({'result': 'PASS', 'bridge_pid': owner.pid,
                          'same_pi_pid': identity['pi_pid'],
                          'model_calls': 0, 'detached_output_bytes_per_case': 1048576,
                          'disconnected_client': 'emacs' if '--emacs' in sys.argv else 'python'}))
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=5)
        owner.terminate()
        try:
            owner.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(owner.pid, signal.SIGKILL)
            owner.wait(timeout=5)
        log.close()
        print('Bridge stopped; socket removed:', not SOCKET.exists())

if __name__ == '__main__':
    if sys.argv[1] == 'bridge':
        asyncio.run(bridge())
    elif sys.argv[1] == 'client':
        client(sys.argv[2])
    else:
        test()
