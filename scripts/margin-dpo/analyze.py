"""Regrade saved matched baseline responses with v3; never rerun baseline inference."""
import pathlib,json,sys,datetime,html,statistics,collections
repo=pathlib.Path(__file__).resolve().parents[2];out=repo/'docs/evals/margin-lora/dpo-pilot/evaluation'
sys.path.insert(0,str(repo/'scripts/margin-model-eval-v3'));from grading import grade
from policy import upgrade
m=json.loads((out/'manifest.json').read_text());rows=[json.loads(l) for l in (out/'results.jsonl').read_text().splitlines()]
oldroot=repo/'docs/evals/margin-lora/pilot2-preparation/thinking-experiment';oldm=json.loads((oldroot/'manifest.json').read_text());old=[json.loads(l) for l in (oldroot/'results.jsonl').read_text().splitlines() if not json.loads(l)['think']]
byid={c['id']:c for c in oldm['cases']};comparison=[]
for r in old:
 if r['status']=='infrastructure':continue
 c=upgrade(byid[r['id']]);errors,_=grade(c,r['response'],oldm['snapshot']);comparison.append(dict(model=r['model'],id=r['id'],repeat=r['repeat'],status='fail' if errors else 'pass',severity=c['severity'],errors=errors,latency=r['latency']))
# Only compare identical prompts, context, schemas and options under the same thinking mode/runtime.
matched=set()
for suite in m['suites']:
 for c in suite['cases']:
  if c['id'] in byid and c['prompt']==byid[c['id']]['prompt'] and c.get('context',[])==byid[c['id']].get('context',[]) and suite['manifest']['snapshot']==oldm['snapshot'] and suite['manifest']['profile']==oldm['profile']:matched.add(c['id'])
comparison=[r for r in comparison if r['id'] in matched]+[r for r in rows if r['id'] in matched]
def stats(rr):
 v=[r for r in rr if r['status']!='infrastructure'];lat=[r['latency'] for r in v]
 return dict(valid=len(v),passed=sum(r['status']=='pass' for r in v),critical=sum(r['status']=='fail' and r['severity']=='critical' for r in v),infrastructure=len(rr)-len(v),median=statistics.median(lat) if lat else None)
summary=dict(timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(),overall=stats(rows),suites={s:stats([r for r in rows if r['suite']==s]) for s in sorted({r['suite'] for r in rows})},matched_cases=len(matched),matched_comparison={mod:stats([r for r in comparison if r['model']==mod]) for mod in sorted({r['model'] for r in comparison})})
(out/'analysis.json').write_text(json.dumps(summary,indent=2));(out/'matched-comparison.json').write_text(json.dumps(comparison,indent=2))
e=html.escape
page='<h1>DPO: did it improve Margin?</h1><p>Updated '+summary['timestamp']+'</p>'
s=summary['overall'];page+=f'<p><strong>{s["passed"]}/{len(rows)} attempted requests passed ({s["valid"]} produced gradable outputs) · {s["critical"]} critical failures · {s["infrastructure"]} infrastructure errors.</strong></p>'
page+='<p>'+('Do not promote this adapter: critical failures or runtime errors remain.' if s['critical'] or s['infrastructure'] else 'No critical failures observed in this run. This does not establish 99% real-world reliability.')+'</p>'
page+='<p>These are raw model outputs. No calendar, file, or memory action was executed. Native safeguards are separately tested; a blocked wrong proposal is not successful task completion.</p>'
def table(groups):
 t='<table><tr><th>Group</th><th>Pass / attempted</th><th>Gradable</th><th>Critical failures</th><th>Runtime errors</th><th>Median</th></tr>'
 for name,s in groups.items():t+=f'<tr><td>{e(name)}</td><td>{s["passed"]}/{s["valid"]+s["infrastructure"]}</td><td>{s["valid"]}</td><td>{s["critical"]}</td><td>{s["infrastructure"]}</td><td>{round(s["median"],2) if s["median"] else "—"} s</td></tr>'
 return t+'</table>'
page+='<h2>Assessment</h2><p>DPO does not improve the tested service overall: 300/381 attempted requests passed (78.7%). On the identical 20-case workstation subset, DPO passes 36/60 attempts versus base 42/60. It improves one quoted-memory case but regresses attendee handling and causes parser errors on two previously working batch cases.</p><p>The 15 critical-labelled failures include nine inappropriate memory writes, three wrong tool routes for emptying Trash, and three unnecessary refusals to describe capabilities. This label does not mean 15 destructive actions occurred: no tools executed. Date moves also lose original dates or choose the wrong destination.</p><p>33 requests across 11 distinct fixtures failed Ollama native tool-call parsing. They are recorded as runtime errors, excluded from gradable-output accuracy, and included as unsuccessful attempts above. The first error was separately reproduced and its body retained. This prevents an inflated accuracy claim based only on responses that survived parsing.</p><h2>Next engineering work</h2><p>Keep this adapter experimental. First capture raw generation for the failing native-format cases to distinguish malformed model output from parser incompatibility; do not patch the evaluator to accept invalid calls. Then improve training coverage for original-date retention, memory provenance and temporary instructions, with new held-out variations. Keep execution safeguards independently tested. Another training run should follow a diagnosed failure mechanism, not simply more epochs.</p><h2>Full evaluation</h2>'+table(summary['suites'])+'<p>Original suite: 96 model fixtures × 3 repetitions; 12 deterministic dispatch fixtures excluded from model scoring. Pilot 2 holdout: 17 × 3. Fresh DPO developer holdout: 14 × 3. Repetitions do not count as independent new tasks.</p>'
page+='<h2>Matched comparison — existing outputs reused</h2><p>'+str(len(matched))+' identical cases, each repeated three times. Prior base and SFT outputs are regraded with evaluator v3, with thinking disabled and the same workstation runtime. This subset is selected for known failures and is not an overall model ranking. No baseline inference was repeated. Timing is from separate sessions.</p>'+table(summary['matched_comparison'])
page+='<h2>Failures by category</h2>'+table({cat:stats([r for r in rows if r['category']==cat]) for cat in sorted({r['category'] for r in rows})})
for suite in m['suites']:
 failed=[r for r in rows if r['suite']==suite['name'] and r['status']=='fail'];cases={c['id']:c for c in suite['cases']}
 if not failed:continue
 page+='<h2>'+e(suite['name'])+' — inspect failures</h2>'
 for ident in dict.fromkeys(r['id'] for r in failed):
  rr=[r for r in failed if r['id']==ident];r=rr[0]
  page+='<details><summary>'+e(ident+' · '+r['category']+f' · failed {len(rr)}/3')+'</summary><p>'+e(cases[ident]['prompt'])+'</p><pre>'+e(json.dumps(dict(errors=r.get('errors'),actual=r.get('actual')),indent=2))+'</pre></details>'
page+='<p><a href="report.html">Live categorized results</a> · <a href="manifest.json">Run manifest</a> · <a href="results.jsonl">Every raw response</a> · <a href="analysis.json">Summary data</a></p>'
(out/'analysis.html').write_text('<!doctype html><meta charset="utf-8"><title>Margin DPO assessment</title><style>body{max-width:1100px;margin:40px auto;padding:24px;background:#f7f5ed;color:#263b2c;font:16px/1.6 system-ui}h1,h2{font-family:Georgia}td,th{padding:12px;text-align:left;border-bottom:1px solid #bbb}pre{white-space:pre-wrap;background:#e8ecdf;padding:14px}details{margin:12px 0}</style>'+page)
print(json.dumps(summary,indent=2))
