import pathlib,subprocess,json,datetime,sys,fcntl,time
r=pathlib.Path(__file__).resolve().parent
lock=(r/'run.lock').open('w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
def state(stage,**kw):(r/'supervisor.json').write_text(json.dumps(dict(timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(),stage=stage,**kw)))
try:
 for candidate in json.loads((r/'manifest.json').read_text())['candidates']:
  if (r/'STOP').exists():raise RuntimeError('Stop requested')
  if (r/(candidate+'-complete.json')).exists():continue
  state('running',candidate=candidate)
  with (r/(candidate+'.log')).open('a') as log:subprocess.run([sys.executable,'-u',str(r/'worker.py'),'--root',str(r),'--candidate',candidate],stdout=log,stderr=subprocess.STDOUT,check=True)
  # Process exit destroys this candidate's CUDA context before the next load.
  time.sleep(2)
 state('complete')
except Exception as ex:state('stopped',error=str(ex));raise
