"""Summarize a completed thinking ablation without changing scored evidence."""
import pathlib,json,collections,statistics,html,datetime
root=pathlib.Path(__file__).resolve().parents[2]/'docs/evals/margin-lora/pilot2-preparation/thinking-experiment'
s=json.loads((root/'summary.json').read_text());assert s['stage']=='complete','Run not complete';m=json.loads((root/'manifest.json').read_text());rows=[json.loads(x) for x in (root/'results.jsonl').read_text().splitlines()];assert len(rows)==360 and not any(x['status']=='infrastructure' for x in rows)
e=html.escape;page='<h1>Thinking-mode results</h1><p>Completed analysis '+datetime.datetime.now(datetime.timezone.utc).isoformat()+'</p><p>360 scored requests on RTX 5070 Ti, Ollama 0.30.10; 20 diagnostic cases × 3 repeats × 3 models × 2 modes. Native chat API. No model training or app change. These selected regression cases do not replace the full suite.</p><table><tr><th>Model</th><th>Thinking</th><th>Pass</th><th>Critical failed requests</th><th>Median</th></tr>'
for a in s['arms']:page+=f'<tr><td>{a["model"]}</td><td>{a["think"]}</td><td>{a["passed"]}/{a["tested"]}</td><td>{a["critical"]}</td><td>{a["median"]:.2f}s</td></tr>'
page+='</table>';details=[]
for model in m['models']:
 page+='<h2>'+e(model)+'</h2><table><tr><th>Case</th><th>On</th><th>Off</th><th>Off failures</th></tr>'
 for c in m['cases']:
  rr=[r for r in rows if r['model']==model and r['id']==c['id']];on=sum(r['status']=='pass' for r in rr if r['think']);off=sum(r['status']=='pass' for r in rr if not r['think']);errors=sorted({err for r in rr if not r['think'] for err in r.get('errors',[])})
  details.append(dict(model=model,id=c['id'],on=on,off=off,errors=errors));page+=f'<tr><td>{e(c["id"])}: {e(c["prompt"])}</td><td>{on}/3</td><td>{off}/3</td><td>{e("; ".join(errors))}</td></tr>'
 page+='</table>'
page+='<h2>Interpretation limits</h2><p>Thinking disabled must be confirmed through output traces and the preflight. JSON-constrained memory output may naturally contain no reasoning even in the enabled arm; that is part of this production-path test. Speed measures are workstation-local. Before promoting any configuration, run the full versioned suite and fresh holdouts. A gain from changing inference mode does not prove the training mismatch was the sole cause.</p><p><a href="report.html">Run summary</a> · <a href="results.jsonl">Raw outputs</a> · <a href="preflight.json">Switch checks</a></p>'
(root/'analysis.json').write_text(json.dumps(details,indent=2));(root/'analysis.html').write_text('<!doctype html><html><meta charset="utf-8"><title>Thinking analysis</title><style>body{margin:35px auto;max-width:1200px;padding:24px;background:#f7f5ed;color:#263b2c;font:16px/1.5 system-ui}td,th{padding:10px;border-bottom:1px solid #ccc;text-align:left}h1,h2{font-family:Georgia}</style>'+page+'</html>');print(json.dumps(s['arms']))
