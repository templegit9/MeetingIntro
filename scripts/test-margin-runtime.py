#!/usr/bin/env python3
"""Exercise the pinned engine and supervisor without pulling a model or touching user AI."""
import argparse, hashlib, json, os, pathlib, socket, subprocess, tempfile, time, urllib.request
from datetime import datetime, timezone
p = argparse.ArgumentParser()
p.add_argument('app'); p.add_argument('archive'); p.add_argument('output')
a = p.parse_args()
started = datetime.now(timezone.utc).isoformat()
manifest = json.loads((pathlib.Path(a.app) / 'Contents/Resources/MarginLocalAI.json').read_text())
supervisor = str(pathlib.Path(a.app) / 'Contents/MacOS/MarginRuntimeSupervisor')
checks = []
def check(name, value):
    checks.append({'name':name, 'pass': bool(value), 'timestamp':datetime.now(timezone.utc).isoformat()})
    print(('PASS' if value else 'FAIL') + ' · ' + name, flush=True)
def wait_for(predicate, seconds=12):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        if predicate(): return True
        time.sleep(.2)
    return False
with tempfile.TemporaryDirectory(prefix='margin-runtime-check-') as temp:
    archive = pathlib.Path(a.archive)
    check('Official runtime archive matches pinned SHA-256', hashlib.sha256(archive.read_bytes()).hexdigest() == manifest['runtimeSHA256'])
    if not checks[-1]['pass']: raise SystemExit(1)
    subprocess.run(['/usr/bin/tar', '-xzf', str(archive), '-C', temp], check=True)
    check('Archive links stay inside installation', all(str(f.resolve()).startswith(str(pathlib.Path(temp).resolve()) + '/') for f in pathlib.Path(temp).rglob('*')))
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', supervisor], check=True)
    check('Supervisor signature verifies', True)
    with socket.socket() as s:
        s.bind(('127.0.0.1',0)); port=s.getsockname()[1]
    env = dict(os.environ, OLLAMA_HOST=f'127.0.0.1:{port}', OLLAMA_MODELS=temp+'/models', OLLAMA_NO_CLOUD='1')
    def version():
        try:
            with urllib.request.urlopen(f'http://127.0.0.1:{port}/api/version', timeout=.4) as r: return json.load(r).get('version') == manifest['runtimeVersion']
        except Exception: return False
    child = subprocess.Popen([supervisor, temp+'/ollama'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        check('Packaged engine starts on its own loopback port', wait_for(version,30))
        child.terminate(); child.wait(timeout=10)
        check('Stopping supervisor stops its engine', wait_for(lambda: not version()))
    finally:
        if child.poll() is None: child.terminate(); child.wait(timeout=10)
    # A disposable owner process imitates MeetingIntro; killing only that owner must stop the engine.
    owner_script = 'import subprocess,time,sys; p=subprocess.Popen(sys.argv[1:]); print(p.pid,flush=True); time.sleep(60)'
    owner = subprocess.Popen(['python3','-c',owner_script,supervisor,temp+'/ollama'], env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        helper_pid = int(owner.stdout.readline().strip())
        check('Engine starts under disposable app owner', wait_for(version,30))
        owner.kill(); owner.wait(timeout=5)
        check('App crash stops the owned engine', wait_for(lambda: not version(),12))
    finally:
        if owner.poll() is None: owner.kill(); owner.wait()
        try: os.kill(helper_pid,15)
        except ProcessLookupError: pass
    check('No model downloaded during lifecycle tests', not list(pathlib.Path(temp,'models').glob('blobs/sha256-*')))
result={'started':started,'ended':datetime.now(timezone.utc).isoformat(),'checks':checks,'passed':sum(c['pass'] for c in checks),'total':len(checks),'scope':'Real pinned runtime; no fresh 14 GB model download.'}
pathlib.Path(a.output).write_text(json.dumps(result,indent=2)+'\n')
raise SystemExit(0 if all(c['pass'] for c in checks) else 1)
