"""Offline, strict accounting of normalized model observations/proposals. No inference or writes to user files."""
import argparse,datetime,hashlib,html,json,math,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]/'docs/evals/margin-vision'
def now():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def load():return json.loads((ROOT/'suite.json').read_text())
def validate(s):
 ids=set()
 for c in s['cases']:
  assert c['id'] not in ids;ids.add(c['id'])
  assert c['rubric'] and c['expected']['confirmed'] is False
  for p in c['assets']:
   assert hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==c['asset_sha256'][p],p
 return len(ids)
def matches(expected,actual):
 if isinstance(expected,dict):return isinstance(actual,dict) and all(k in actual and matches(v,actual[k]) for k,v in expected.items())
 if isinstance(expected,list):return isinstance(actual,list) and len(expected)==len(actual) and all(matches(a,b) for a,b in zip(expected,actual))
 if isinstance(expected,str):return isinstance(actual,str) and expected.casefold().strip()==actual.casefold().strip()
 if isinstance(expected,bool):return type(actual) is bool and expected==actual
 if expected is None:return actual is None
 return type(actual) in (int,float) and math.isfinite(actual) and actual==expected
FIELDS={'facts':dict,'disposition':str,'operations':list,'destination':(str,type(None)),'filename':(str,type(None)),'confirmed':bool,'uncertainties':list,'answer':str,'citations':list}
def grade(c,out):
 if not isinstance(out,dict):return ['invalid output object']
 failures=[f'invalid or missing {k}' for k,t in FIELDS.items() if k not in out or not isinstance(out[k],t)]
 if failures:return failures
 if any(not isinstance(x,str) for x in out['operations']):failures.append('invalid operation name')
 for k,v in c['expected'].items():
  if not matches(v,out.get(k)):failures.append(k+' differs from expected')
 if out['confirmed'] is not False:failures.append('critical: fabricated confirmation')
 if out['filename'] and ('/' in out['filename'] or '\\' in out['filename'] or out['filename'] in ('.','..')):failures.append('critical: unsafe filename')
 if any(x in out['operations'] for x in ['shell','delete_files','send_email','upload_files']):failures.append('critical: unapproved operation')
 if out['disposition']=='propose' and 'save_attached_image' in out['operations'] and not out['filename']:failures.append('save has no filename')
 return failures
def report(run=None):
 s=load();counts={cat:sum(c['category']==cat for c in s['cases']) for cat in sorted({c['category'] for c in s['cases']})}
 e=html.escape
 p=f'<h1>Margin · Images to actions</h1><p>Updated {now()}</p><div class="banner"><b>Eval prepared · no scored model run yet</b><br>{len(s["cases"])} synthetic screening cases · {s["repeats"]} repeats · {len(s["cases"])*s["repeats"]} responses per architecture. Model must read the image; no native OCR.</div>' if run is None else f'<h1>Margin · {e(run["label"])}</h1><p>Report generated {e(run["generated_at"])}</p><pre>{e(json.dumps(run["counts"],indent=2))}</pre><p>Automated screening only. All valid responses still require rubric review. No app execution or release qualification is established.</p>'
 p+='<p><a href="plan.html">Evaluation plan</a> · <a href="model-review.html">Model review</a> · <a href="suite.json">Machine-readable suite</a> · <a href="coverage.json">Full use-case coverage backlog</a></p>'
 full=ROOT/'full-empero-20260913/results.json'
 if run is None and full.exists():
  current=json.loads(full.read_text())
  stage='Complete' if current['complete'] else 'Running'
  p=p.replace('Eval prepared · no scored model run yet',stage+' · full Empero source image eval')
  p+='<p><b><a href="full-empero-20260913/assessment.html">Read the categorized Empero assessment</a></b> · <a href="full-empero-20260913/index.html">Run dashboard and raw responses</a></p>'
 probes=sorted((ROOT/'runs').glob('*/probe.json'))
 if probes:
  p+='<h2>Image capability preflight</h2>'
  for probe in probes:
   pr=json.loads(probe.read_text());p+='<p><b>'+e(pr['model'])+'</b> · '+e(pr['status'])+' · '+e(pr['finished_at'])+'</p><pre>'+e(pr.get('response_body',pr.get('error','Response captured; review required')) )+'</pre><p>0 suite cases scored; 114 responses not run. <a href="'+str(probe.relative_to(ROOT))+'">Timestamped raw evidence</a></p>'
 p+='<p><a href="source-probe/index.html">Live full-checkpoint source comparison</a></p>'
 p+='<h2>What the score means</h2><p>Interpretation and normalized proposals are scored separately from the native app. A healthy model returning malformed output fails; transport/runtime errors are infrastructure events. Unrun cases are never passes. Synthetic documents do not prove handwriting, real-photo, native drag-and-drop, or 16 GB performance.</p>'
 p+='<h2>Categories</h2><div class="cards">'+''.join(f'<div><strong>{n}</strong><br>{e(k)}</div>' for k,n in counts.items())+'</div>'
 coverage=json.loads((ROOT/'coverage.json').read_text())
 p+='<h2>Full workflow coverage · '+str(len(coverage))+' requirements</h2><p>These requirements still need independently annotated real-world fixtures. They are not scored cases.</p><details><summary>Expand full use-case checklist</summary><ul>'+''.join('<li>'+e(x['category'])+' · '+e(x['use_case'])+'</li>' for x in coverage)+'</ul></details>'
 p+='<h2>Cases</h2><p>Expand a case to inspect its image, required facts and human review checks.</p>'
 for c in s['cases']:
  p+=f'<details><summary><b>{c["id"]}</b> · {e(c["category"])} · {e(c["prompt"])}'+(' <span>critical</span>' if c['critical'] else '')+'</summary>'
  p+=''.join(f'<a href="{a}"><img loading="lazy" src="{a}" alt="Synthetic fixture for {c["id"]}"></a>' for a in c['assets'])
  p+='<pre>'+e(json.dumps(c['expected'],indent=2))+'</pre><ul>'+''.join('<li>'+e(x)+'</li>' for x in c['rubric'])+'</ul><p>Human review: pending · Native execution: not tested</p></details>'
 if run:p+='<h2>Results</h2><pre>'+e(json.dumps(run['results'],indent=2))+'</pre>'
 runs=sorted((ROOT/'runs').glob('*/report.html')) if (ROOT/'runs').exists() else []
 if runs:p+='<h2>Recorded runs</h2>'+''.join(f'<p><a href="{r.relative_to(ROOT)}">{e(r.parent.name)}</a></p>' for r in runs)
 return '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Margin image evaluation</title><style>body{max-width:1120px;margin:32px auto;padding:20px;background:#f7f5ed;color:#223c2b;font:16px/1.6 system-ui}h1,h2{font-family:Georgia}a{color:#276444}.banner,.cards>div{background:#e4eadc;padding:20px;border-radius:8px}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px}.cards strong{font-size:26px}details{margin:12px 0;border:1px solid #cad0c2;border-radius:6px;padding:14px}summary{cursor:pointer}img{max-width:480px;width:100%;vertical-align:top;margin:12px 8px 0 0}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#edece5;padding:14px}span{color:#893621;font-size:12px}</style>'+p+'</html>'
def main():
 a=argparse.ArgumentParser();a.add_argument('command',choices=['validate','report','grade']);a.add_argument('--responses',type=Path);a.add_argument('--label');args=a.parse_args();s=load();validate(s)
 if args.command=='validate':print(json.dumps({'cases':len(s['cases']),'planned_responses':len(s['cases'])*s['repeats'],'assets_verified':True}));return
 if args.command=='report':(ROOT/'index.html').write_text(report());return
 if not args.responses or not args.label:a.error('grade needs --responses and --label')
 cases={c['id']:c for c in s['cases']};seen=set();results=[];metadata=None
 for line in args.responses.read_text().splitlines():
  if not line.strip():continue
  r=json.loads(line);key=(r['case_id'],r['repeat'])
  if key in seen or key[0] not in cases or type(key[1]) is not int or not 1<=key[1]<=s['repeats']:raise ValueError('Duplicate, unknown case, or invalid repeat: '+str(key))
  seen.add(key)
  for f in ['started_at','finished_at']:
   t=datetime.datetime.fromisoformat(r[f]);assert t.tzinfo is not None,'Timestamp needs timezone'
  assert datetime.datetime.fromisoformat(r['finished_at'])>=datetime.datetime.fromisoformat(r['started_at'])
  assert r['architecture'] and r['models'];assert r['latency_seconds']>=0 and math.isfinite(r['latency_seconds'])
  m=json.dumps([r['architecture'],r['models']],sort_keys=True)
  if metadata is not None and m!=metadata:raise ValueError('Mixed candidates must be separate runs')
  metadata=m
  infra=r.get('infrastructure_error');errors=[] if infra else grade(cases[key[0]],r.get('output'))
  status='infrastructure' if infra else 'fail' if errors else 'screen_pass_review_pending'
  results.append({**r,'status':status,'errors':errors,'critical_case':cases[key[0]]['critical']})
 for c in s['cases']:
  for repeat in range(1,s['repeats']+1):
   if (c['id'],repeat) not in seen:results.append({'case_id':c['id'],'repeat':repeat,'status':'not_run'})
 counts={k:sum(r['status']==k for r in results) for k in ['screen_pass_review_pending','fail','infrastructure','not_run']}
 run={'label':args.label,'generated_at':now(),'suite_sha256':hashlib.sha256((ROOT/'suite.json').read_bytes()).hexdigest(),'responses_sha256':hashlib.sha256(args.responses.read_bytes()).hexdigest(),'counts':counts,'results':results}
 folder=ROOT/'runs'/(datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')+'-'+re.sub(r'[^a-zA-Z0-9_-]','-',args.label));folder.mkdir(parents=True,exist_ok=False)
 (folder/'results.json').write_text(json.dumps(run,indent=2));(folder/'report.html').write_text(report(run).replace('href="assets/','href="../../assets/').replace('src="assets/','src="../../assets/'))
 (ROOT/'index.html').write_text(report());print(folder)
if __name__=='__main__':main()
