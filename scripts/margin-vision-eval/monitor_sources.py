"""Read-only SSH monitor; serves a static report through the existing local report server."""
import pathlib,subprocess,json,datetime,time,html
R=pathlib.Path(__file__).resolve().parents[2];out=R/'docs/evals/margin-vision/source-probe';out.mkdir(exist_ok=True)
for _ in range(240):
 t=datetime.datetime.now(datetime.timezone.utc).isoformat()
 try:
  p=subprocess.run(['python3',str(R/'scripts/margin-lora/workstation.py'),str(R/'scripts/margin-vision-eval/workstation_status.py')],capture_output=True,text=True,timeout=35)
  if p.returncode:raise RuntimeError(p.stderr[-600:])
  d=json.loads(p.stdout);d['fetched_at']=t;(out/'snapshot.json').write_text(json.dumps(d,indent=2))
  e=html.escape;s=d['status'] or {};body='<h1>Margin · full-checkpoint image test</h1><p>Updated '+t+'</p><h2>'+e(s.get('stage','starting'))+'</h2><p>'+e(s.get('model',''))+'</p><p>GPU: '+e(d['gpu'])+'</p><p>Workstation RTX 5070 Ti · one candidate at a time · no training. These are feasibility probes, not the 114-response suite or a Mac latency benchmark.</p>'
  for model,rows in d['results'].items():
   body+='<h2>'+e(model)+' · '+str(len(rows))+'/7 responses</h2>'
   for row in rows:body+='<details open><summary>'+e(row['id'])+' · '+str(round(row['latency_seconds'],1))+'s</summary><pre>'+e(row['output'])+'</pre><small>Image tensor: '+str(row['image_tensor_present'])+' · Truncated: '+str(row['truncated'])+'</small></details>'
  body+='<details><summary>Runtime log</summary><pre>'+e(d['log_tail'])+'</pre></details><p><a href="../index.html">Image eval catalogue</a> · <a href="snapshot.json">Raw snapshot</a></p>'
  (out/'index.html').write_text('<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="20"><title>Margin vision source test</title><style>body{max-width:1050px;margin:35px auto;padding:20px;background:#f7f5ed;color:#243c2d;font:16px/1.6 system-ui}h1,h2{font-family:Georgia}pre{white-space:pre-wrap;overflow-wrap:anywhere}details{border:1px solid #b9c7b5;padding:15px;margin:12px 0}</style>'+body)
  print(t,s.get('stage'),{k:len(v) for k,v in d['results'].items()},flush=True)
  if d['complete'] or s.get('stage')=='infrastructure failure':break
 except Exception as ex:print(t,'Monitor error',str(ex),flush=True)
 time.sleep(20)
