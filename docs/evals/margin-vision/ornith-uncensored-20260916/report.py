import json,html,statistics,datetime
E=lambda x:html.escape(str(x))
def render(root):
 s=json.loads((root/'status.json').read_text()) if (root/'status.json').exists() else {'stage':'prepared'}
 rows=[json.loads(x) for x in (root/'responses.jsonl').read_text().splitlines()] if (root/'responses.jsonl').exists() else []
 valid=[r for r in rows if r['status'] in ['pass','fail']];fails=[r for r in valid if r['status']=='fail'];infra=[r for r in rows if r['status']=='infrastructure']
 b='<h1>Ornith 1.5 9B Uncensored</h1><p>Margin evaluation · Q4_K_M · this Mac · one model at a time</p><div class="banner"><b>'+E(s['stage'])+'</b> · '+str(len(valid))+'/117 scored · '+str(len(valid)-len(fails))+' passed · '+str(len(fails))+' failed · '+str(len(infra))+' runtime errors</div><p>Updated: '+E(s.get('timestamp','Not started'))+'<br>Current: '+E(s.get('suite',''))+' '+E(s.get('case',''))+'</p><p>96 language/tool requests + 20 image-evidence planning requests + 1 explicit search request. Image readings are reused from the earlier reader; this does <b>not</b> measure Ornith image recognition. Twelve deterministic dispatch rows are excluded. No actions execute.</p>'
 if s.get('error'):b+='<pre>'+E(s['error'])+'</pre>'
 b+='<h2>Results by category</h2><table><tr><th>Category</th><th>Pass / scored</th><th>Critical failures</th><th>Median</th></tr>'
 for cat in sorted({r['category'] for r in valid}):
  rr=[r for r in valid if r['category']==cat];b+='<tr>'+''.join('<td>'+E(v)+'</td>' for v in [cat,str(sum(r['status']=='pass' for r in rr))+'/'+str(len(rr)),sum(r['status']=='fail' and r['critical'] for r in rr),str(round(statistics.median(r['seconds'] for r in rr),1))+'s'])+'</tr>'
 b+='</table><h2>What failed</h2>'
 if not fails:b+='<p>No scored failures yet. Unrun cases are not passes.</p>'
 for r in fails:b+='<p><b>'+E(r['suite']+' / '+r['id'])+'</b> — '+E('; '.join(r['errors']))+'</p>'
 b+='<h2>Every response</h2>'
 for r in rows:
  if r['status']=='deterministic':continue
  b+='<details><summary>'+E(r['suite']+' · '+r['id']+' · '+r['status'])+'</summary><pre>'+E(json.dumps(r,indent=2))+'</pre></details>'
 b+='<h2>Comparison limits</h2><p>Same frozen prompts, profile and scoring as Pilot 1 hybrid v2, including original-rubric errors. One repetition on a development suite. This run does not qualify app integration, actual writes, or image recognition.</p><p><a href="../hybrid-pilot1-v2-20260913/index.html">Pilot 1 comparison</a> · <a href="manifest.json">Frozen manifest</a> · <a href="responses.jsonl">Raw responses</a></p>'
 return '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><meta http-equiv="refresh" content="20"><title>Margin · Ornith evaluation</title><style>body{max-width:1100px;margin:32px auto;padding:24px;background:#f7f5ed;color:#24382c;font:16px/1.6 system-ui}h1,h2{font-family:Georgia}.banner{padding:20px;background:#e4eadc}table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:12px;border-bottom:1px solid #c7d0c1}pre{white-space:pre-wrap;overflow-wrap:anywhere}details{padding:8px}a{color:#286346}</style>'+b+'</html>'
