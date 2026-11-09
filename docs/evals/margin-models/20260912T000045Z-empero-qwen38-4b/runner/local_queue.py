"""Run the frozen installed candidates serially; never download models."""
import json, pathlib, subprocess, sys, time, datetime, urllib.request, shutil, hashlib, re
from report import build

root=pathlib.Path(sys.argv[1]).resolve()
manifest=json.loads((root/'manifest.json').read_text())
runner=pathlib.Path(__file__).with_name('run.py').resolve()
def status(stage, **details):
    data=dict(timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(),stage=stage,**details)
    (root/'queue-status.json').write_text(json.dumps(data,indent=2)+'\n')
    print(data,flush=True)
def idle():
    with urllib.request.urlopen('http://127.0.0.1:11434/api/ps',timeout=10) as response:
        if json.load(response)['models']: raise RuntimeError('Another model is loaded; queue stopped before switching')

def ensure_installed(model):
    download=manifest.get('downloads',{}).get(model)
    with urllib.request.urlopen('http://127.0.0.1:11434/api/tags',timeout=10) as response:
        installed=model in {m['name'] for m in json.load(response)['models']}
    if installed:
        if download: verify_download(model,download)
        return
    if '--pull-missing' not in sys.argv: raise RuntimeError('Model not installed: '+model)
    sizes={'granite4.2:8b':5_300_000_000,'qwen3.5:9b':6_600_000_000,'qwen3.5:4b':3_400_000_000}
    if download: sizes[model]=download['bytes_budget']
    if model not in sizes: raise RuntimeError('Download not budgeted: '+model)
    if shutil.disk_usage(root).free<sizes[model]+3*1024**3: raise RuntimeError('Insufficient space for '+model+' and 3 GiB reserve')
    status('downloading',model=model)
    with (root/(model.replace(':','-')+'-download.log')).open('x') as log:
        source=download['source'] if download else model
        subprocess.run(['ollama','pull',source],stdout=log,stderr=subprocess.STDOUT,check=True)
        if download:
            verify_download(source,download)
            subprocess.run(['ollama','cp',source,model],stdout=log,stderr=subprocess.STDOUT,check=True)

def verify_download(model,download):
    req=urllib.request.Request('http://127.0.0.1:11434/api/show',data=json.dumps({'model':model}).encode(),headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=10) as response: info=json.load(response)
    match=re.search(r'^FROM (.+)$',info['modelfile'],re.M)
    if not match: raise RuntimeError('Cannot locate imported GGUF for verification')
    path=pathlib.Path(match[1].strip().strip('"'))
    with path.open('rb') as f: digest=hashlib.file_digest(f,'sha256').hexdigest()
    if digest!=download['sha256']: raise RuntimeError('GGUF checksum differs from pinned publisher artifact')
    (root/'package-verification.json').write_text(json.dumps(dict(model=model,sha256=digest,source=download,verified_at=datetime.datetime.now(datetime.timezone.utc).isoformat()),indent=2)+'\n')

try:
    if manifest.get('after_run'):
        predecessor=pathlib.Path(manifest['after_run'])/'queue-status.json'
        status('waiting_for_previous_run',previous=str(predecessor.parent))
        while True:
            if (root/'STOP').exists(): raise RuntimeError('STOP requested')
            state=json.loads(predecessor.read_text())
            if state['stage']=='completed': break
            if state['stage'] in ('needs_attention','cancelled'): raise RuntimeError('Previous run stopped; inspect it before loading another model')
            time.sleep(10)
    for model in manifest['models']:
        if (root/'STOP').exists(): raise RuntimeError('STOP requested')
        idle()
        ensure_installed(model)
        if (root/'STOP').exists(): raise RuntimeError('STOP requested')
        idle()
        status('evaluating',model=model)
        with (root/(model.replace(':','-')+'-console.log')).open('x') as log:
            child=subprocess.Popen([sys.executable,str(runner),str(root),'--model',model],stdout=log,stderr=subprocess.STDOUT)
            while child.poll() is None:
                build(root)
                # A STOP marker prevents the next model; current requests finish normally.
                time.sleep(10)
        build(root)
        metadata=json.loads((root/(model.replace(':','-')+'-run.json')).read_text())
        if child.returncode or metadata['status']!='completed':
            raise RuntimeError(model+': '+metadata.get('reason','Runner did not complete'))
        idle()
    status('completed')
except Exception as error:
    status('needs_attention',reason=str(error))
finally:
    build(root)
