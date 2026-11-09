import pathlib,json,subprocess,time,datetime
import importlib,render_dashboard
root=pathlib.Path(__file__).resolve().parents[2];out=root/'docs/evals/margin-vision/training-20260913';out.mkdir(exist_ok=True)
while True:
 try:
  x=subprocess.run(['python3',str(root/'scripts/margin-lora/workstation.py'),str(root/'scripts/margin-vision-training/status_remote.py')],capture_output=True,text=True,timeout=35);x.check_returncode();d=json.loads(x.stdout);d['fetched_at']=datetime.datetime.now(datetime.timezone.utc).isoformat()
  tmp=out/'status.tmp';tmp.write_text(json.dumps(d,indent=2));tmp.replace(out/'status.json');(out/'index.html').write_text(importlib.reload(render_dashboard).render(d));print(d.get('status'),flush=True)
 except Exception as ex:
  print(str(ex),flush=True)
  try:d=json.loads((out/'status.json').read_text())
  except (OSError,ValueError):d={}
  (out/'index.html').write_text(importlib.reload(render_dashboard).render(d,error=str(ex)))
 time.sleep(20)
