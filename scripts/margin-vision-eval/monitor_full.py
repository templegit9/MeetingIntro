import pathlib,subprocess,json,datetime,time,html,importlib.util,statistics
from diagnostics import inspect
R=pathlib.Path(__file__).resolve().parents[2];out=R/'docs/evals/margin-vision/full-empero-20260913';out.mkdir(exist_ok=True)
spec=importlib.util.spec_from_file_location('grader',R/'scripts/margin-vision-eval/eval.py');g=importlib.util.module_from_spec(spec);spec.loader.exec_module(g);cases={c['id']:c for c in g.load()['cases']}
for _ in range(360):
 t=datetime.datetime.now(datetime.timezone.utc).isoformat()
 try:
  p=subprocess.run(['python3',str(R/'scripts/margin-lora/workstation.py'),str(R/'scripts/margin-vision-eval/full_status.py')],capture_output=True,text=True,timeout=35)
  if p.returncode:raise RuntimeError(p.stderr[-600:])
  d=json.loads(p.stdout);d['fetched_at']=t;(out/'snapshot.json').write_text(json.dumps(d,indent=2))
  if d['manifest']:(out/'manifest.json').write_text(json.dumps(d['manifest'],indent=2))
  (out/'responses.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in d['responses']))
  rows=[]
  for r in d['responses']:
   errors=g.grade(cases[r['case_id']],r.get('output')) if not r.get('infrastructure_error') else []
   rows.append({**r,'diagnostics':inspect(cases[r['case_id']],r),'errors':errors,'status':'infrastructure' if r.get('infrastructure_error') else 'fail' if errors else 'screen_pass_review_pending'})
  counts={k:sum(r['status']==k for r in rows) for k in ['screen_pass_review_pending','fail','infrastructure']};counts['not_run']=114-len(rows)
  (out/'results.json').write_text(json.dumps({'updated_at':t,'complete':bool(d['complete']),'counts':counts,'results':rows},indent=2))
  e=html.escape;s=d['status'] or {};body='<h1>Margin · Empero image eval</h1><p>Updated '+t+'</p><h2>'+e(s.get('stage','starting'))+' · '+str(len(rows))+'/114 responses</h2><p>Workstation RTX 5070 Ti · Full Empero 4B BF16 · No native OCR · No tool execution · No training</p><div class="cards">'+''.join('<div><b>'+str(v)+'</b><br>'+e(k.replace('_',' '))+'</div>' for k,v in counts.items())+'</div><p>Screening passes still require semantic review. Failure counts are provisional: exact-field mismatches must be distinguished from actual misunderstandings before training. Repeats are consistency checks, not independent images.</p><p>GPU: '+e(d['gpu'])+'</p>'
  eligible=sum(r['diagnostics'].get('facts_eligible',False) for r in rows)
  facts=sum(r['diagnostics'].get('facts_exact',False) for r in rows)
  fences=sum(r['diagnostics'].get('format')=='markdown_fenced_json' for r in rows)
  plans=sum(r['diagnostics'].get('plan_exact',False) for r in rows)
  body+='<h2>Why strict checks fail</h2><p><b>'+str(fences)+'</b> responses wrapped JSON in Markdown. Separately, <b>'+str(facts)+'/'+str(eligible)+'</b> eligible responses match the annotated image facts exactly, and <b>'+str(plans)+'/'+str(len(rows))+'</b> match the annotated plan fields after decoding plain or fenced JSON. These diagnostics do not change the strict score; semantic review is still pending. Empty fact rubrics are excluded.</p>'
  body+='<h2>Categories</h2><table><tr><th>Category</th><th>Screen pass</th><th>Fail</th><th>Infra</th><th>Not run</th></tr>'
  for cat in sorted({c['category'] for c in cases.values()}):
   selected=[r for r in rows if r['category']==cat];planned=sum(c['category']==cat for c in cases.values())*3
   body+='<tr><td>'+e(cat)+'</td>'+''.join('<td>'+str(sum(r['status']==k for r in selected))+'</td>' for k in ['screen_pass_review_pending','fail','infrastructure'])+'<td>'+str(planned-len(selected))+'</td></tr>'
  body+='</table><h2>Responses · failures first</h2>'
  for r in sorted(rows,key=lambda x:(x['status']!='fail',x['case_id'],x['repeat'])):
   c=cases[r['case_id']];body+='<details><summary>'+r['case_id']+' / '+str(r['repeat'])+' · '+e(r['status'])+' · '+e(c['prompt'])+'</summary><p>'+e('; '.join(r['errors']))+'</p>'+''.join('<img src="../'+f+'" alt="Fixture '+c['id']+'">' for f in c['assets'])+'<h3>Expected screening fields</h3><pre>'+e(json.dumps(c['expected'],indent=2))+'</pre><h3>Actual model response</h3><pre>'+e(r.get('raw_response',r.get('infrastructure_error','')) )+'</pre></details>'
  body+='<p><a href="manifest.json">Frozen run manifest</a> · <a href="responses.jsonl">Raw responses</a> · <a href="results.json">Checks JSON</a> · <a href="../index.html">Eval catalogue</a></p><details><summary>Runtime log</summary><pre>'+e(d['log_tail'])+'</pre></details>'
  (out/'index.html').write_text('<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="20"><title>Margin full image eval</title><style>body{max-width:1100px;margin:32px auto;padding:20px;background:#f7f5ed;color:#243c2d;font:16px/1.6 system-ui}h1,h2{font-family:Georgia}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#eeede4;padding:14px}details{border:1px solid #c3ccba;padding:12px;margin:10px 0}table{width:100%;border-collapse:collapse}td,th{padding:10px;text-align:left;border-bottom:1px solid #ccd0c1}.cards{display:flex;gap:12px;flex-wrap:wrap}.cards>div{background:#e1e8d6;padding:18px}.cards b{font-size:28px}img{max-width:420px;width:100%}a{color:#29633f}</style>'+body)
  print(t,s.get('stage'),counts,flush=True)
  if d['complete'] or s.get('stage')=='infrastructure failure':break
 except Exception as ex:print(t,'Monitor error',str(ex),flush=True)
 time.sleep(20)
