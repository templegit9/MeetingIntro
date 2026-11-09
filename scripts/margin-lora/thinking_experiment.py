"""Workstation-only native-chat thinking ablation; no tools actually execute."""
import pathlib,json,hashlib,datetime,urllib.request,urllib.error,time,re,sys,statistics,html,subprocess
repo=pathlib.Path(__file__).resolve().parents[2];out=repo/'docs/evals/margin-lora/pilot2-preparation/thinking-experiment';out.mkdir(exist_ok=True)
sys.path.insert(0,str(repo/'scripts/margin-model-eval-v2'));from grading import grade
from policy import upgrade
from transformers import AutoTokenizer
base=next(pathlib.Path('/private/tmp/margin-audit-local/cache/huggingface/hub/models--empero-ai--Qwen3.8-4B-Distill/snapshots').iterdir());tokenizer=AutoTokenizer.from_pretrained(str(base))
api_base='http://127.0.0.1:18771'
def stamp():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def api(path,data=None):
 with urllib.request.urlopen(urllib.request.Request(api_base+path,data=None if data is None else json.dumps(data).encode(),headers={'Content-Type':'application/json'}),timeout=150) as r:return json.load(r)
m=json.loads((out.parent/'regression-eval/manifest.json').read_text());h=json.loads((out.parent/'holdout-eval/manifest.json').read_text());byid={c['id']:c for c in m['cases']+h['cases']}
ids=['args-4','routing-43','research-1','research-2','learn-7','reason-1','reason-2','args-2','routing-25','boundary-1','boundary-2','routing-4','routing-11','routing-29','p2-batch1','p2-batch2','p2-move4','p2-memory','p2-r2','p2-r3'];cases=[upgrade(byid[x]) for x in ids];snapshot=m['snapshot'];models=['margin-think-base:audit','margin-think-pilot1:audit','margin-think-pilot2:audit'];records=[]
manifest=dict(created=stamp(),host='Temple-Workstation RTX 5070 Ti',runtime=api('/api/version'),models=models,cases=cases,repetitions=3,profile=m['profile'],method='Native Ollama chat with think true/false. Original prompts, tools, profile, and learning JSON schema retained; workstation runtime 0.30.10.',snapshot=snapshot,template_sha256=hashlib.sha256(str(tokenizer.chat_template).encode()).hexdigest(),code_sha256=hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest())
if (out/'results.jsonl').exists():
 records=[json.loads(x) for x in (out/'results.jsonl').read_text().splitlines()]
 old=json.loads((out/'manifest.json').read_text());assert old['cases']==cases and old['models']==models and old['profile']==m['profile']
 (out/'continuation.json').write_text(json.dumps(dict(timestamp=stamp(),reason='Wait for asynchronous unload confirmation; preserve completed base requests',previous_manifest_sha256=hashlib.sha256((out/'manifest.json').read_bytes()).hexdigest(),continuation_script_sha256=manifest['code_sha256']),indent=2))
else:
 (out/'manifest.json').write_text(json.dumps(manifest,indent=2));(out/'manifest.sha256').write_text(hashlib.sha256((out/'manifest.json').read_bytes()).hexdigest())
clock='Current local time: Thursday, September 10, 2026 at 12:00 PM (America/Los_Angeles).\nRequest: '
def render(case,think):
 kind=case['kind'];system=snapshot['system'] if kind=='routing' else snapshot['learning_system'] if kind=='learning' else snapshot['research_system'] if kind=='research' else 'Answer the user accurately and concisely. Do not claim to have performed actions. Use only information supplied or stable arithmetic and timezone rules.'
 messages=[{'role':'system','content':system}]+case.get('context',[])+[{'role':'user','content':(clock if kind=='routing' else '')+case['prompt']}]
 return messages
def report(stage):
 sums=[]
 for model in models:
  for think in [True,False]:
   rr=[r for r in records if r['model']==model and r['think']==think];valid=[r for r in rr if r['status']!='infrastructure'];lat=[r['latency'] for r in valid]
   sums.append(dict(model=model,think=think,tested=len(valid),expected=len(cases)*3,passed=sum(r['status']=='pass' for r in valid),critical=sum(r['status']=='fail' and r['severity']=='critical' for r in valid),infra=len(rr)-len(valid),median=statistics.median(lat) if lat else None))
 data=dict(stage=stage,updated=stamp(),arms=sums);(out/'summary.json').write_text(json.dumps(data,indent=2))
 page='<h1>Thinking-mode experiment</h1><p>'+stamp()+' · '+html.escape(stage)+'</p><p>Inference: RTX 5070 Ti workstation. One model at a time. Native chat API, same prompts/tools/settings in both modes. Only think changes. Workstation latency is not comparable to Mac latency.</p><table><tr><th>Model</th><th>Thinking</th><th>Pass / tested</th><th>Critical</th><th>Infrastructure</th><th>Median</th></tr>'
 for s in sums:page+=f'<tr><td>{s["model"]}</td><td>{s["think"]}</td><td>{s["passed"]}/{s["tested"]} of {s["expected"]}</td><td>{s["critical"]}</td><td>{s["infra"]}</td><td>{s["median"] and round(s["median"],2)}</td></tr>'
 page+='</table><p><a href="manifest.json">Frozen manifest</a> · <a href="results.jsonl">Every raw output and grade</a> · <a href="preflight.json">Switch preflight</a></p>'
 (out/'report.html').write_text('<!doctype html><html><meta charset="utf-8"><meta http-equiv="refresh" content="15"><style>body{max-width:1100px;margin:35px auto;padding:20px;background:#f7f5ed;color:#263b2c;font:16px/1.5 system-ui}td,th{padding:10px;border-bottom:1px solid #ccc}h1{font-family:Georgia}</style>'+page+'</html>')
report('preflight')
pre=json.loads((out/'preflight.json').read_text()) if (out/'preflight.json').exists() else []
try:
 assert not api('/api/ps')['models'],'Another model is loaded'
 for mi,model in enumerate(models):
  completed=[r for r in records if r['model']==model]
  if len(completed)==len(cases)*6:continue
  assert not completed,'Cannot silently restart a partial model arm'
  package=next(x for x in api('/api/tags')['models'] if x['name']==model)
  (out/(model.replace(':','-')+'-package.json')).write_text(json.dumps(package,indent=2))
  # Per-model switch validation before scoring. No fabricated preflight scores.
  for think in [True,False]:
   case={'kind':'reasoning','prompt':'What is 17 times 23? Answer briefly.'}
   r=api('/api/chat',dict(model=model,messages=render(case,think),think=think,stream=False,options=m['profile'],keep_alive='5m'))
   msg=r['message'];ok=bool(msg.get('thinking')) if think else not msg.get('thinking') and '<think>' not in msg.get('content','')
   pre.append(dict(model=model,think=think,passed=ok,response=r));(out/'preflight.json').write_text(json.dumps(pre,indent=2));assert ok,('Thinking switch ineffective',model,think)
  loaded=api('/api/ps')['models'];assert len(loaded)==1 and loaded[0]['name']==model and loaded[0].get('size_vram',0)>0,'Workstation GPU residency not established'
  (out/(model.replace(':','-')+'-gpu-residency.json')).write_text(json.dumps(loaded,indent=2))
  # Alternate pair order to reduce systematic timing bias while retaining one resident model.
  for rep in range(1,4):
   for i,case in enumerate(cases):
    for think in ([True,False] if (i+rep)%2 else [False,True]):
     active=api('/api/ps')['models'];assert len(active)==1 and active[0]['name']==model,'Concurrent or unexpected model'
     t=time.monotonic();row=dict(model=model,think=think,repeat=rep,id=case['id'],category=case['category'],severity=case['severity'],timestamp=stamp())
     try:
      req=dict(model=model,messages=render(case,think),think=think,tools=snapshot['tools'] if case['kind']=='routing' else [],stream=False,options=m['profile'],keep_alive='5m')
      if case['kind']=='learning':req['format']=snapshot['learning_schema']
      r=api('/api/chat',req);message=r['message'];response=r
      errors,actual=grade(case,response,snapshot)
      if not think and message.get('thinking'):errors.append('Thinking emitted despite disabled template')
      row.update(status='fail' if errors else 'pass',errors=errors,actual=actual,response=r,parsed=message)
     except (urllib.error.URLError,TimeoutError) as e:row.update(status='infrastructure',error=str(e))
     row['latency']=time.monotonic()-t;records.append(row)
     with (out/'results.jsonl').open('a') as f:f.write(json.dumps(row)+'\n')
     report('running');print(model,think,case['id'],rep,row['status'],flush=True)
     if row['status']=='infrastructure':raise RuntimeError('Stop on infrastructure failure')
  api('/api/generate',{'model':model,'keep_alive':0})
  for _ in range(100):
   if not api('/api/ps')['models']:break
   time.sleep(.2)
  else:raise RuntimeError('Model did not unload within 20 seconds')
 report('complete')
finally:
 # Unload only experiment-owned models.
 for loaded in api('/api/ps')['models']:
  if loaded['name'] in models:api('/api/generate',{'model':loaded['name'],'keep_alive':0})
