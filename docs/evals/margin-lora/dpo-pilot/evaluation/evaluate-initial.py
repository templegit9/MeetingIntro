"""Resume-safe workstation DPO export watcher and sequential, versioned evaluation."""
import pathlib,json,sys,time,datetime,hashlib,subprocess,urllib.request,statistics,html,traceback
repo=pathlib.Path(__file__).resolve().parents[2]
out=repo/'docs/evals/margin-lora/dpo-pilot/evaluation';out.mkdir(exist_ok=True)
sys.path.insert(0,str(repo/'scripts/margin-model-eval-v3'))
from grading import grade
from policy import upgrade
host='oluyi@100.126.58.91';remote='/mnt/c/Users/oluyi/Documents/Projects/Margin-Empero-DPO';apiroot='http://127.0.0.1:18771';model='margin-dpo:pilot'
def now():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def api(path,data=None):
 with urllib.request.urlopen(urllib.request.Request(apiroot+path,data=None if data is None else json.dumps(data).encode(),headers={'Content-Type':'application/json'}),timeout=180) as r:return json.load(r)
def ssh(command,timeout=60):return subprocess.check_output(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=10',host,command],text=True,timeout=timeout)
rows=[]
def report(stage,**extra):
 groups={}
 for x in rows:
  key=(x['suite'],x['category']);groups.setdefault(key,[]).append(x)
 s=dict(stage=stage,updated=now(),completed=len(rows),planned=381,**extra)
 (out/'status.json').write_text(json.dumps(s,indent=2))
 page='<h1>Margin DPO evaluation</h1><p>'+html.escape(stage)+' · Updated '+s['updated']+'</p><p>'+str(len(rows))+' / 381 requests recorded. Workstation RTX 5070 Ti; thinking disabled; evaluator v3. No real tools execute.</p><p>Critical failures, safe refusals, and task success are distinct. Training loss is not accuracy. Consumer model unchanged.</p><table><tr><th>Suite / category</th><th>Pass / valid</th><th>Critical failures</th><th>Infrastructure</th><th>Median</th></tr>'
 for (suite,category),rr in sorted(groups.items()):
  valid=[x for x in rr if x['status']!='infrastructure'];lat=[x['latency'] for x in valid]
  page+=f'<tr><td>{html.escape(suite+" / "+category)}</td><td>{sum(x["status"]=="pass" for x in valid)}/{len(valid)}</td><td>{sum(x["status"]=="fail" and x["severity"]=="critical" for x in valid)}</td><td>{len(rr)-len(valid)}</td><td>{round(statistics.median(lat),2) if lat else "—"} s</td></tr>'
 page+='</table><h2>Failures to inspect</h2>'
 for x in rows:
  if x['status']!='pass':page+='<details><summary>'+html.escape(f'{x["suite"]} · {x["id"]} · repeat {x["repeat"]} · {x["status"]}')+'</summary><pre>'+html.escape(json.dumps(x.get('errors',x.get('error')),indent=2))+'</pre></details>'
 page+='<p><a href="manifest.json">Frozen run manifest</a> · <a href="results.jsonl">Raw results</a> · <a href="status.json">Status</a></p>'
 (out/'report.html').write_text('<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="20"><title>Margin DPO evaluation</title><style>body{max-width:1100px;margin:35px auto;padding:24px;background:#f7f5ed;color:#263b2c;font:16px/1.5 system-ui}td,th{padding:10px;text-align:left;border-bottom:1px solid #ccc}pre{white-space:pre-wrap}h1,h2{font-family:Georgia}</style>'+page)
try:
 report('Waiting for adapter export')
 for _ in range(720):
  s=json.loads(ssh('wsl -d Ubuntu-24.04 -- cat '+remote+'/status.json'))
  if s['stage']=='failed':raise RuntimeError(s)
  if s['stage']=='exports_ready':break
  report('Export: '+s['stage']);time.sleep(15)
 else:raise RuntimeError('Export wait exceeded three hours')
 (out/'export-manifest.json').write_text(json.dumps(s,indent=2))
 assert not api('/api/ps')['models'],'Unexpected resident model; do not evict other work'
 report('Importing quantized adapter')
 # Import executes only on the isolated Windows runtime, never the Mac runtime.
 ps="$env:OLLAMA_HOST='127.0.0.1:11436'; & 'D:\\llm\\margin-ollama-0.30.10\\ollama.exe' create margin-dpo:pilot -f 'C:\\Users\\oluyi\\Documents\\Projects\\Margin-Empero-DPO\\DPO.Modelfile'; exit $LASTEXITCODE"
 import base64
 result=ssh('powershell -NoProfile -EncodedCommand '+base64.b64encode(ps.encode('utf-16le')).decode(),timeout=600);(out/'import.log').write_text(result)
 suites=[]
 for name,p in [('Original',repo/'docs/evals/margin-lora/pilot2-preparation/regression-eval/manifest.json'),('Pilot 2 holdout',repo/'docs/evals/margin-lora/pilot2-preparation/holdout-eval/manifest.json'),('Fresh DPO holdout',out.parent/'holdout-manifest.json')]:
  m=json.loads(p.read_text());suites.append((name,m,[upgrade(c) for c in m['cases'] if not c.get('direct')]))
 manifest=dict(started=now(),model=model,runtime=api('/api/version'),thinking=False,repetitions=3,suites=[dict(name=n,manifest=m,cases=c) for n,m,c in suites],script_sha256=hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),grading_sha256=hashlib.sha256((repo/'scripts/margin-model-eval-v3/grading.py').read_bytes()).hexdigest())
 assert sum(len(c) for _,_,c in suites)*3==381
 if (out/'manifest.json').exists():
  old=json.loads((out/'manifest.json').read_text());assert old['suites']==manifest['suites'] and old['script_sha256']==manifest['script_sha256']
  rows=[json.loads(l) for l in (out/'results.jsonl').read_text().splitlines()] if (out/'results.jsonl').exists() else []
 else:(out/'manifest.json').write_text(json.dumps(manifest,indent=2))
 pre=api('/api/chat',dict(model=model,messages=[dict(role='user',content='Return only this JSON object: {"ready":true}')],think=False,stream=False,options=suites[0][1]['profile'],keep_alive='5m'))
 (out/'reload-preflight.json').write_text(json.dumps(pre,indent=2));assert pre.get('done') and not pre['message'].get('thinking') and pre['message'].get('content'),'Reload preflight invalid'
 residency=api('/api/ps')['models'];assert len(residency)==1 and residency[0]['name']==model and residency[0].get('size_vram',0)>0
 (out/'gpu-residency.json').write_text(json.dumps(residency,indent=2))
 completed={(x['suite'],x['id'],x['repeat']) for x in rows if x['status']!='infrastructure'}
 for suite,m,cases in suites:
  snapshot=m['snapshot']
  for rep in range(1,4):
   for c in cases:
    if (suite,c['id'],rep) in completed:continue
    active=api('/api/ps')['models'];assert len(active)==1 and active[0]['name']==model
    kind=c['kind'];system=snapshot['system'] if kind=='routing' else snapshot['learning_system'] if kind=='learning' else snapshot['research_system'] if kind=='research' else 'Answer the user accurately and concisely. Do not claim to have performed actions. Use only information supplied or stable arithmetic and timezone rules.'
    prefix='Current local time: Thursday, September 10, 2026 at 12:00 PM (America/Los_Angeles).\nRequest: ' if kind=='routing' else ''
    messages=[dict(role='system',content=system)]+c.get('context',[])+[dict(role='user',content=prefix+c['prompt'])]
    req=dict(model=model,messages=messages,tools=snapshot['tools'] if kind=='routing' else [],think=False,stream=False,options=m['profile'],keep_alive='5m')
    if kind=='learning':req['format']=snapshot['learning_schema']
    row=dict(suite=suite,id=c['id'],repeat=rep,category=c['category'],severity=c['severity'],timestamp=now(),model=model);t=time.monotonic()
    try:
     response=api('/api/chat',req);errors,actual=grade(c,response,snapshot)
     if response['message'].get('thinking'):errors.append('Thinking emitted while disabled')
     row.update(status='fail' if errors else 'pass',errors=errors,actual=actual,response=response)
    except Exception as e:row.update(status='infrastructure',error=str(e))
    row['latency']=time.monotonic()-t;rows.append(row)
    with (out/'results.jsonl').open('a') as f:f.write(json.dumps(row)+'\n')
    report('Evaluating',current=suite+' / '+c['id']);print(suite,c['id'],rep,row['status'],flush=True)
    if row['status']=='infrastructure':raise RuntimeError(row['error'])
 report('Evaluation complete — comparison review pending')
except Exception:
 report('Stopped on infrastructure error',error=traceback.format_exc());raise
finally:
 try:
  for x in api('/api/ps')['models']:
   if x['name']==model:api('/api/generate',dict(model=model,keep_alive=0))
 except Exception:pass
