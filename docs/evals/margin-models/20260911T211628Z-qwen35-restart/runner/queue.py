#!/usr/bin/env python3
"""Serial queue controller. Does not change frozen prompts, grading or model settings."""
import datetime, json, os, pathlib, shutil, subprocess, sys, threading, time, urllib.request
from report import build
ROOT=pathlib.Path(sys.argv[1]);RUNNER=pathlib.Path(__file__).with_name('run.py');BASE='http://127.0.0.1:11434'
def now(): return datetime.datetime.now(datetime.timezone.utc).isoformat()
def api(path,data=None,timeout=120):
    req=urllib.request.Request(BASE+path,data=None if data is None else json.dumps(data).encode(),headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=timeout) as r:return json.load(r)
def status(stage,**extra):
    (ROOT/'queue-status.json').write_text(json.dumps(dict(timestamp=now(),stage=stage,**extra),indent=2)+'\n');print(now(),stage,extra,flush=True)
def stopped():return (ROOT/'STOP').exists()
def idle():
    loaded=api('/api/ps')['models']
    if loaded:raise RuntimeError('A model remains loaded; queue will not load a second model: '+','.join(m['name'] for m in loaded))
def pull(model):
    # Pull only missing small candidates. Existing packages are never replaced or removed.
    if model in {m['name'] for m in api('/api/tags')['models']}:return
    needed={'gpt-oss:20b':14_000_000_000,'gemma4:12b':7_600_000_000}[model]
    if shutil.disk_usage(ROOT).free<needed+2*1024**3:raise RuntimeError('Insufficient disk to download '+model+' with a 2 GiB reserve')
    status('downloading',model=model)
    req=urllib.request.Request(BASE+'/api/pull',data=json.dumps({'model':model,'stream':True}).encode(),headers={'Content-Type':'application/json'})
    success=False;last=0
    with urllib.request.urlopen(req,timeout=3600) as response:
        for line in response:
            if stopped():raise RuntimeError('User stop marker')
            data=json.loads(line)
            if 'error' in data:raise RuntimeError(data['error'])
            if data.get('status')=='success':success=True
            if time.monotonic()-last>30:status('downloading',model=model,progress=data);last=time.monotonic()
    if not success:raise RuntimeError('Download ended without success')
def execute(model):
    idle()
    meta=ROOT/(model.replace(':','-')+'-run.json')
    if meta.exists():raise RuntimeError('Refusing duplicate run '+model)
    status('evaluating',model=model)
    with (ROOT/(model.replace(':','-')+'-console.log')).open('w') as log:
        process=subprocess.Popen([sys.executable,str(RUNNER),str(ROOT),'--model',model],stdout=log,stderr=subprocess.STDOUT)
        while process.poll() is None:
            build(ROOT)
            if stopped():
                process.terminate();process.wait(timeout=15)
                api('/api/generate',{'model':model,'keep_alive':0})
                if meta.exists():
                    state=json.loads(meta.read_text());state.update(status='cancelled',finished=now(),reason='STOP marker');meta.write_text(json.dumps(state,indent=2))
                raise RuntimeError('User stop marker')
            time.sleep(10)
    if process.returncode:raise RuntimeError('Runner failed; see console log')
    idle();build(ROOT)
    state=json.loads(meta.read_text())
    if state['status']!='completed':
        raise RuntimeError('Stopping queue after incomplete model run: '+model+'; '+state.get('reason','See run metadata'))
try:
    status('waiting_for_first_model',model='qwen3.5:9b')
    first=ROOT/'qwen3.5-9b-run.json'
    while not first.exists() or json.loads(first.read_text())['status']=='running':
        if stopped():raise RuntimeError('STOP marker; first runner must be stopped separately')
        build(ROOT);time.sleep(10)
    first_state=json.loads(first.read_text())
    if first_state['status']!='completed':
        raise RuntimeError('First model did not complete; preserve results and resolve the interruption before a new run: '+first_state.get('reason','See run metadata'))
    idle()
    for model in ['qwen3.8:27b','gpt-oss:20b','gemma4:12b']:
        if stopped():raise RuntimeError('User stop marker')
        if model in ['gpt-oss:20b','gemma4:12b']:pull(model)
        execute(model)
    # This candidate's published default package is ~23 GB, above this Mac's weight budget.
    target=ROOT/'qwen3.6-35b-run.json'
    target.write_text(json.dumps({'model':'qwen3.6:35b','status':'hardware_blocked','started':now(),'finished':now(),'reason':'Default package is about 23 GB on a 24 GB Mac. Exceeds the frozen 75% model-weight budget before runtime/context/macOS. Not downloaded; no quality score.','source':'https://ollama.com/library/qwen3.6'},indent=2)+'\n')
    build(ROOT);status('finished_available_candidates')
except Exception as error:
    status('needs_attention',reason=str(error));build(ROOT);raise
