import pathlib,subprocess,json,time,datetime,sys
import report,importlib
repo=pathlib.Path(__file__).resolve().parents[2];out=repo/'docs/evals/margin-vision/separated-20260913b'
while True:
 try:
  run=subprocess.run([sys.executable,str(repo/'scripts/margin-lora/workstation.py'),str(pathlib.Path(__file__).with_name('status_remote.py'))],capture_output=True,text=True,timeout=40);run.check_returncode()
  for name,content in json.loads(run.stdout).items():
   assert pathlib.Path(name).name==name
   temp=out/(name+'.tmp');temp.write_text(content);temp.replace(out/name)
  (out/'fetched.json').write_text(json.dumps({'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat()}))
 except Exception as ex:(out/'fetched.json').write_text(json.dumps({'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'error':str(ex)}))
 importlib.reload(report);(out/'index.html').write_text(report.render(out))
 time.sleep(20)
