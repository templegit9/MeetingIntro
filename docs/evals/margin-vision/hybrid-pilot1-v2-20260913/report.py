import pathlib,json,html,statistics
E=lambda x:html.escape(str(x))
def render(root):
 try:s=json.loads((root/'status.json').read_text())
 except (ValueError,OSError):s={'stage':'prepared'}
 rows=[]
 try:
  for line in (root/'responses.jsonl').read_text().splitlines():
   try:rows.append(json.loads(line))
   except ValueError:pass
 except OSError:pass
 body='<h1>Hybrid v2 · Evidence handoff and calendar fidelity</h1><p><b>'+E(s.get('stage'))+'</b> · '+E(s.get('completed',0))+'/117 · '+E(s.get('suite',''))+' '+E(s.get('case',''))+'</p><p>Worker timestamp: '+E(s.get('timestamp','Not started'))+'</p><p>Saved image readings are reused. Only Pilot 1 is loaded, on this Mac. No tools execute. The original workstation comparison remains unchanged. Cross-runtime latency is not directly comparable.</p><p><a href="review.html">Read the remaining-failure review and scoring caveats</a></p>'
 if s.get('error'):body+='<pre>'+E(s['error'])+'</pre>'
 body+='<table><tr><th>Stage</th><th>Recorded / planned</th><th>Revised pass / valid</th><th>Failures on critical cases</th><th>Infrastructure</th><th>Median</th></tr>'
 for stage,total in [('predicted_planner',10),('gold_planner',10),('explicit_content',1),('language',96)]:
  rr=[r for r in rows if r['suite']==stage and r['status']!='deterministic'];valid=[r for r in rr if r['status'] in ['pass','fail']]
  vals=[stage,f'{len(rr)}/{total}',f'{sum(r["status"]=="pass" for r in valid)}/{len(valid)}',sum(r['status']=='fail' and r['critical'] for r in rr),sum(r['status']=='infrastructure' for r in rr),f'{statistics.median(r["seconds"] for r in valid):.1f}s' if valid else '—'];body+='<tr>'+''.join('<td>'+E(v)+'</td>' for v in vals)+'</tr>'
 body+='</table><p>Version 2 accepts explicit safe-refusal synonyms, filename search for the ambiguous project request, and a correctly described detailed-explanation preference under format. Citation, all-day, uncertainty and tool-schema checks remain required. Each response retains original-rubric errors too. This is a development-set repair run, not independent holdout validation.</p><h2>Every response</h2>'
 for r in rows:
  if r['status']=='deterministic':continue
  body+='<details><summary>'+E(r['suite']+' · '+r['id']+' · '+r['status'])+'</summary><pre>'+E(json.dumps(r,indent=2))+'</pre></details>'
 body+='<p><a href="../hybrid-pilot1-20260913/index.html">Original hybrid run</a> · <a href="manifest.json">Frozen manifest</a> · <a href="../separated-20260913b/index.html">Four-checkpoint comparison</a> · <a href="../training-20260913/index.html">Training dashboard</a></p>'
 return '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><meta http-equiv="refresh" content="20"><title>Margin · Hybrid planner evaluation</title><style>body{max-width:1200px;margin:30px auto;padding:20px;background:#f7f5ed;color:#24382c;font:16px/1.6 system-ui}h1,h2{font-family:Georgia}table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:12px;border-bottom:1px solid #c7d0c1}th{background:#e4eadc}pre{white-space:pre-wrap;overflow-wrap:anywhere}details{padding:10px}a{color:#286346}</style>'+body+'</html>'
if __name__=='__main__':
 import sys
 r=pathlib.Path(sys.argv[1]);(r/'index.html').write_text(render(r))
