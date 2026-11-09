"""Offline rescore of immutable stored responses; never represented as new inference."""
import pathlib,json,hashlib,datetime,collections,html
from grading import grade
from policy import upgrade,VERSION
repo=pathlib.Path(__file__).resolve().parents[2];base=repo/'docs/evals/margin-lora';out=base/'pilot2-preparation/audit-v2';out.mkdir(exist_ok=False)
sources=[('Base regression',base/'20260912T045552Z-final-comparison','margin-lora-base-control-preflight'),('Pilot 1 regression',base/'20260912T045552Z-final-comparison','margin-lora-pilot-final'),('Pilot 2 regression',base/'pilot2-preparation/regression-eval','margin-lora-pilot2-final'),('Base holdout',base/'pilot2-preparation/holdout-eval','margin-lora-base-control-preflight'),('Pilot 2 holdout',base/'pilot2-preparation/holdout-eval','margin-lora-pilot2-final')]
summary=[];provenance=[];diffs=[]
for label,root,key in sources:
 manifest=json.loads((root/'manifest.json').read_text());cases={c['id']:upgrade(c) for c in manifest['cases']};rows=[]
 for line in (root/(key+'.jsonl')).read_text().splitlines():
  row=json.loads(line)
  if row['status'] not in ['pass','fail']:continue
  case=cases[row['id']];errors,actual=grade(case,row['response'],manifest['snapshot']);status='fail' if errors else 'pass';new=dict(id=row['id'],repeat=row['repeat'],status=status,original_status=row['status'],severity=case['severity'],errors=errors,actual=actual);rows.append(new)
  if status!=row['status']:diffs.append(dict(model=label,**new))
 (out/(key+('-holdout' if 'holdout' in label else '')+'.jsonl')).write_text(''.join(json.dumps(x)+'\n' for x in rows))
 summary.append(dict(model=label,valid=len(rows),passed=sum(x['status']=='pass' for x in rows),critical=sum(x['status']=='fail' and x['severity']=='critical' for x in rows)))
 provenance.append(dict(label=label,source=str(root),manifest_sha256=hashlib.sha256((root/'manifest.json').read_bytes()).hexdigest(),responses_sha256=hashlib.sha256((root/(key+'.jsonl')).read_bytes()).hexdigest(),derived_cases=list(cases.values())))
result=dict(version=VERSION,timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(),mode='offline replay; no new inference',summary=summary,changes=diffs)
(out/'summary.json').write_text(json.dumps(result,indent=2));(out/'provenance.json').write_text(json.dumps(dict(sources=provenance,code_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in pathlib.Path(__file__).parent.glob('*.py')}),indent=2))
e=html.escape
page='<h1>Evaluator v2 audit</h1><p>'+e(result['timestamp'])+'</p><p>Offline regrading of saved responses, not a new model run. Original evidence is unchanged. Corrects date-move clock invention, research uncertainty wording, and explicit critical severity for negative memory fixtures.</p><table><tr><th>Saved run</th><th>Passed</th><th>Critical failed requests</th></tr>'
for s in summary:page+=f'<tr><td>{e(s["model"])}</td><td>{s["passed"]}/{s["valid"]}</td><td>{s["critical"]}</td></tr>'
page+='</table><h2>Changed verdicts</h2>'
for d in diffs:page+=f'<p>{e(d["model"])} · {d["id"]} repeat {d["repeat"]}: {d["original_status"]} → {d["status"]}. {e(str(d["errors"]))}</p>'
page+='<p>The move fixture now forbids invented clock times; it deliberately does not resolve the ambiguous Thursday wording into one exact date. Semantic completeness beyond these checks remains a limitation.</p><p><a href="summary.json">Scores and verdict changes</a> · <a href="provenance.json">Input hashes and derived fixtures</a></p>'
(out/'report.html').write_text('<!doctype html><html><meta charset="utf-8"><title>Margin evaluator audit</title><style>body{max-width:1000px;margin:40px auto;padding:24px;background:#f7f5ed;color:#243b2d;font:16px/1.6 system-ui}td,th{padding:12px;border-bottom:1px solid #ccc;text-align:left}h1,h2{font-family:Georgia}</style>'+page+'</html>')
print(json.dumps(summary))
