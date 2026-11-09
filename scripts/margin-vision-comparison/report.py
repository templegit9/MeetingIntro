import json,pathlib,html,collections,statistics,datetime
from zoneinfo import ZoneInfo
def local_time(value):
 try:return datetime.datetime.fromisoformat(value).astimezone(ZoneInfo("America/Los_Angeles")).strftime("%b %d, %Y · %I:%M:%S %p %Z")
 except (TypeError,ValueError):return "Not fetched yet"
E=lambda v:html.escape(str(v))
def read(p,default):
 try:return json.loads(p.read_text())
 except (OSError,ValueError):return default
def render(root):
 m=read(root/'manifest.json',{});s=read(root/'supervisor.json',{});w=read(root/'status.json',{});fetched=read(root/'fetched.json',{});health=read(root/'worker-health.json',{})
 body='<h2>Four-candidate comparison</h2><p><b>'+E(s.get('stage','Preparing'))+'</b> · '+E(w.get('candidate',''))+' · '+E(w.get('stage',''))+' · '+E(w.get('suite',''))+' '+E(w.get('case',''))+'</p><p>Last workstation refresh: '+E(local_time(fetched.get('timestamp')))+'</p>'
 if s.get('stage')=='running' and not health.get('worker_pids'):body+='<p class="bad">No active inference worker observed at last refresh; inspect startup or transition status.</p>'
 if fetched.get('error'):body+='<p class="bad">Connection failed; last snapshot retained: '+E(fetched['error'])+'</p>'
 if s.get('stage')=='stopped':body+='<details open><summary>Run interruption (not a model score)</summary><pre>'+E(w.get('error',s.get('error','Unknown')) )+'</pre></details>'
 if (root/'audit.html').exists():body+='<p class="audit"><b><a href="audit.html" target="_blank">Read the completed failure audit and recommended next steps</a></b><br>Image reading, workflow errors, strict formatting and grader defects are separated. Original scores below remain unchanged.</p>'
 body+='<p><b><a target="_blank" href="../separated-20260913b/index.html">New live run: reading versus native planning</a></b> · Corrected contracts, new probes, all four candidates.</p>'
 body+='<p>402 model requests per candidate: 114 image + 288 language. Candidates run sequentially. Deterministic dispatch is excluded. Image fixtures are independent of training, but previously used in source screening. No model is promoted by this report.</p><table><tr><th>Candidate</th><th>State</th><th>Suite</th><th>Recorded / planned</th><th>Passed / valid</th><th>Failures on critical cases</th><th>Infrastructure</th><th>Median</th></tr>'
 allrows=[]
 for c in m.get('candidates',[]):
  rows=[]
  try:
   for line in (root/(c+'.jsonl')).read_text().splitlines():
    try:rows.append(json.loads(line))
    except ValueError:pass
  except OSError:pass
  complete=(root/(c+'-complete.json')).exists();status='Complete' if complete else ('Stopped' if s.get('stage')=='stopped' else 'Running') if s.get('candidate',w.get('candidate'))==c else 'Queued'
  for suite,total in [('image',114),('language',288)]:
   rr=[r for r in rows if r['suite']==suite and r['status']!='deterministic'];valid=[r for r in rr if r['status'] in ['pass','fail']]
   vals=[c,status,suite,f'{len(rr)} / {total}',f'{sum(r["status"]=="pass" for r in valid)} / {len(valid)}',sum(r['status']=='fail' and r['critical'] for r in rr),sum(r['status']=='infrastructure' for r in rr),f'{statistics.median(r["seconds"] for r in valid):.1f}s' if valid else '—']
   body+='<tr>'+''.join('<td>'+E(x)+'</td>' for x in vals)+'</tr>'
  allrows+=rows
 body+='</table><p>Image passes are automated screening only; human rubric review remains pending. Historical Mac latency is not comparable to workstation latency.</p><details><summary>Category breakdown</summary><table><tr><th>Candidate</th><th>Suite / category</th><th>Pass / valid</th><th>Critical failed</th></tr>'
 for key in sorted({(r['candidate'],r['suite'],r['category']) for r in allrows}):
  rr=[r for r in allrows if (r['candidate'],r['suite'],r['category'])==key and r['status'] in ['pass','fail']]
  body+='<tr>'+''.join('<td>'+E(v)+'</td>' for v in [key[0],key[1]+' / '+key[2],f'{sum(r["status"]=="pass" for r in rr)} / {len(rr)}',sum(r['status']=='fail' and r['critical'] for r in rr)])+'</tr>'
 body+='</table></details><h3>Failures and raw evidence</h3>'
 for r in allrows:
  if r['status'] not in ['fail','infrastructure']:continue
  body+='<details><summary>'+E(f'{r["candidate"]} · {r["suite"]} · {r["id"]} · repeat {r["repeat"]} · {r["status"]}')+'</summary><pre>'+E(json.dumps(r,indent=2))+'</pre></details>'
 body+='<p><a href="launch-notes.json">Startup interruptions (excluded from model scores)</a> · <a href="manifest.json">Frozen manifest and limitations</a> · <a href="../training-20260913/index.html">Training dashboard</a></p>'
 return '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><meta http-equiv="refresh" content="20"><title>Margin · Four-candidate evaluation</title><style>body{margin:24px;background:#f7f5ed;color:#24382c;font:15px/1.5 system-ui}h2,h3{font-family:Georgia}table{border-collapse:collapse;width:100%}td,th{padding:10px;text-align:left;border-bottom:1px solid #cbd3c6}pre{white-space:pre-wrap;overflow-wrap:anywhere}.bad{color:#a33}details{padding:10px 0}a{color:#286346}</style>'+body+'</html>'
if __name__=='__main__':
 import sys
 r=pathlib.Path(sys.argv[1]);(r/'index.html').write_text(render(r))
