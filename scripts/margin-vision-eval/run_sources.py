"""Separate child process per candidate guarantees weights leave memory before the next load."""
import pathlib,subprocess,sys,json,datetime
root=pathlib.Path(sys.argv[1]);(root/'results').mkdir(exist_ok=True)
for candidate in [0,1]:
 result=subprocess.run([sys.executable,'-u',str(root/'source_probe.py'),'--root',str(root),'--candidate',str(candidate)])
 with (root/'results/exits.jsonl').open('a') as f:f.write(json.dumps({'candidate':candidate,'exit_code':result.returncode,'finished_at':datetime.datetime.now(datetime.timezone.utc).isoformat()})+'\n')
 # A failed runtime is not a model accuracy result; preserve failure and inspect before proceeding.
 if result.returncode:sys.exit(result.returncode)
(root/'complete.json').write_text(json.dumps({'completed_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'candidates':2,'training_started':False},indent=2))
