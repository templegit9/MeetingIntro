"""Wait for live epoch 1 and its evaluation; preserve them, then train epochs 2–3."""
import pathlib,json,subprocess,time,datetime,shutil
r=pathlib.Path('/mnt/c/Users/oluyi/Documents/Projects/Margin-Vision-Pilot/mixed-pilot-20260913');py='/home/oluyi/.venvs/margin-empero-lora/bin/python'
def state(stage,**kw):
 (r/'epoch-schedule.json').write_text(json.dumps({'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'epochs':3,'eval_after_each_epoch':True,'eval_responses_per_epoch':20,'stage':stage,**kw},indent=2))
try:
 state('waiting for existing epoch 1 and evaluation')
 while True:
  assert not (r/'STOP').exists(),'User stop requested'
  try:s=json.loads((r/'pipeline.json').read_text())
  except (OSError,ValueError):s={}
  if s.get('stage')=='complete; raw comparison ready for review':break
  assert s.get('stage')!='failed',s.get('error')
  time.sleep(10)
 assert len((r/'evaluate-responses.jsonl').read_text().splitlines())==20
 assert not (r/'epoch-1-adapter').exists(),'Epoch 1 archive already exists; refuse overwrite'
 shutil.copytree(r/'pilot-adapter',r/'epoch-1-adapter');shutil.copy2(r/'evaluate-responses.jsonl',r/'epoch-1-responses.jsonl')
 (r/'epoch-1-complete.json').write_text(json.dumps({'epoch':1,'finished':datetime.datetime.now(datetime.timezone.utc).isoformat(),'training_examples':600,'eval_responses':20}))
 state('training and evaluating epochs 2 and 3')
 with (r/'epochs-2-3.log').open('w') as log:subprocess.run([py,'-u',str(r/'train_epoch_continuation.py'),'--root',str(r),'--mode','pilot'],stdout=log,stderr=subprocess.STDOUT,check=True)
 state('complete; three epoch checkpoints and evaluations available')
except Exception as ex:state('failed',error=str(ex));raise
