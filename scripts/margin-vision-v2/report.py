import pathlib,json,html,statistics,datetime
from zoneinfo import ZoneInfo
E=lambda v:html.escape(str(v))
def read(p,default):
 try:return json.loads(p.read_text())
 except (OSError,ValueError):return default
def render(r):
 m=read(r/'manifest.json',{});s=read(r/'supervisor.json',{});w=read(r/'status.json',{});f=read(r/'fetched.json',{});labels={'reader':'Image reading','joint':'Image → native plan','predicted_planner':'Read facts → native plan','gold_planner':'Verified facts → native plan','language':'Full language regression'}
 try:stamp=datetime.datetime.fromisoformat(f.get('timestamp','')).astimezone(ZoneInfo('America/Los_Angeles')).strftime('%b %d · %I:%M:%S %p PDT')
 except ValueError:stamp='Not fetched yet'
 body='<h1>Reading versus planning</h1><p><b>'+E(s.get('stage','Prepared'))+'</b> · '+E(w.get('candidate',''))+' · '+E(w.get('suite',w.get('stage','')))+' · '+E(w.get('case',''))+'</p><p>Last workstation refresh: '+E(stamp)+'</p><p>169 model requests per candidate. Unadapted → epoch 1 → epoch 2 → epoch 3, one loaded at a time. No training and no live tool execution. One repeat per case.</p>'
 body+='<p>33 previously screened images/fact queries plus ten new synthetic cases. Planner tests use those ten new cases. Verified-facts planning deliberately receives annotations to isolate planning ability; other stages never receive expected values. The same checkpoint supplies both stages in this run. Pilot 1 cross-model planning remains a separate follow-up. Image-save and document-write workflows await native tool contracts; this planner test uses registered operations. Passes cover the annotated checks and still require review of unannotated output.</p>'
 if f.get('error') or s.get('stage')=='stopped':body+='<pre class="bad">'+E(f.get('error') or w.get('error') or s.get('error'))+'</pre>'
 body+='<table><tr><th>Candidate</th><th>Stage</th><th>Recorded / planned</th><th>Pass / valid</th><th>Failures on critical cases</th><th>Infrastructure</th><th>Median</th></tr>';allrows=[]
 for candidate in m.get('candidates',[]):
  rows=[]
  try:
   for line in (r/(candidate+'.jsonl')).read_text().splitlines():
    try:rows.append(json.loads(line))
    except ValueError:pass
  except OSError:pass
  allrows+=rows
  for stage,total in m.get('stage_counts',{}).items():
   rr=[x for x in rows if x['suite']==stage and x['status']!='deterministic'];valid=[x for x in rr if x['status'] in ['pass','fail']]
   values=[candidate,labels[stage],f'{len(rr)} / {total}',f'{sum(x["status"]=="pass" for x in valid)} / {len(valid)}',sum(x['status']=='fail' and x['critical'] for x in rr),sum(x['status']=='infrastructure' for x in rr),f'{statistics.median(x["seconds"] for x in valid):.1f}s' if valid else '—']
   body+='<tr>'+''.join('<td>'+E(v)+'</td>' for v in values)+'</tr>'
 body+='</table><p>These stage scores are not comparable to the previous combined proposal score. Format failures remain visible. Reading uses declared semantic checks; native arguments remain typed and permission/confirmation requirements are not relaxed.</p><h2>Failure evidence</h2>'
 for x in allrows:
  if x['status'] in ['fail','infrastructure']:body+='<details><summary>'+E(x['candidate']+' · '+x['suite']+' · '+x['id'])+'</summary><pre>'+E(json.dumps(x,indent=2))+'</pre></details>'
 body+='<p><a href="suite.json">Cases and annotations</a> · <a href="manifest.json">Frozen manifest</a> · <a href="../comparison-20260913/audit.html">Why this experiment</a> · <a href="../training-20260913/index.html">Training dashboard</a></p>'
 return '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="20"><title>Margin · Separated reading and planning</title><style>body{background:#f7f5ed;color:#24382c;font:15px/1.6 system-ui;margin:30px}h1,h2{font-family:Georgia}table{border-collapse:collapse;width:100%}td,th{padding:10px;text-align:left;border-bottom:1px solid #c7d0c1}th{background:#e4eadc}pre{white-space:pre-wrap;overflow-wrap:anywhere}a{color:#286346}.bad{color:#a33}details{padding:10px 0}</style>'+body+'</html>'
if __name__=='__main__':
 import sys
 r=pathlib.Path(sys.argv[1]);(r/'index.html').write_text(render(r))
