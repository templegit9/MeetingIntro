"""Run the frozen installed candidates serially; never download models."""
import json, pathlib, subprocess, sys, time, datetime, urllib.request
from report import build

root=pathlib.Path(sys.argv[1]).resolve()
runner=pathlib.Path(__file__).with_name('run.py').resolve()
def status(stage, **details):
    data=dict(timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(),stage=stage,**details)
    (root/'queue-status.json').write_text(json.dumps(data,indent=2)+'\n')
    print(data,flush=True)
def idle():
    with urllib.request.urlopen('http://127.0.0.1:11434/api/ps',timeout=10) as response:
        if json.load(response)['models']: raise RuntimeError('Another model is loaded; queue stopped before switching')

try:
    for model in json.loads((root/'manifest.json').read_text())['models']:
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
