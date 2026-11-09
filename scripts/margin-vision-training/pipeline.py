"""Sequential authorized run: export gate -> native baseline -> pilot -> native eval."""
import pathlib,json,subprocess,time,datetime,traceback
r=pathlib.Path('/mnt/c/Users/oluyi/Documents/Projects/Margin-Vision-Pilot/mixed-pilot-20260913');py='/home/oluyi/.venvs/margin-empero-lora/bin/python'
def state(stage,**kw):
 (r/'pipeline.json').write_text(json.dumps({'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'stage':stage,**kw},indent=2))
try:
 state('waiting for multimodal export gate')
 deadline=time.monotonic()+7200
 while not (r/'export-gate.json').exists():
  assert time.monotonic()<deadline,'Export gate timed out'
  assert not (r/'STOP').exists(),'User stop requested'
  try:s=json.loads((r/'status.json').read_text())
  except:s={}
  assert s.get('stage')!='failed',s.get('error')
  time.sleep(5)
 assert json.loads((r/'export-gate.json').read_text())['passed']
 for mode in ['baseline','pilot','evaluate']:
  assert not (r/'STOP').exists(),'User stop requested'
  state(mode)
  with (r/(mode+'.log')).open('w') as log:subprocess.run([py,'-u',str(r/'train.py'),'--root',str(r),'--mode',mode],stdout=log,stderr=subprocess.STDOUT,check=True)
 state('complete; raw comparison ready for review')
except Exception:state('failed',error=traceback.format_exc());raise
