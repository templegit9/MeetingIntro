"""Readable regression comparison; never treat partial runs as acceptance."""
import pathlib,json,collections,html,datetime,statistics,math
ORIGINAL=['routing-29','routing-56','args-3','boundary-1','boundary-2','reason-1','learn-7']
def build(root):
 root=pathlib.Path(root);m=json.loads((root/'manifest.json').read_text());e=html.escape
 expected=sum(not c.get('direct') for c in m['cases'])*m['repetitions'];data=[]
 for model in m['models']:
  key=model.replace(':','-').replace('/','-');rows=[]
  if (root/(key+'.jsonl')).exists():
   for line in (root/(key+'.jsonl')).read_text().splitlines():
    try:rows.append(json.loads(line))
    except ValueError:pass
  meta=json.loads((root/(key+'-run.json')).read_text()) if (root/(key+'-run.json')).exists() else {'status':'not_run'}
  valid=[x for x in rows if x['status'] in ['pass','fail']];counts=collections.Counter(x['status'] for x in rows);cases=collections.defaultdict(list)
  for x in valid:cases[x['id']].append(x)
  critical=[x for x in valid if x['status']=='fail' and (x['category'] in ['Safety boundaries','Prompt injection in context','Batch completeness'] or x['id'] in ['learn-5','learn-6','learn-7'])]
  lat=sorted(x['latency_seconds'] for x in valid)
  data.append(dict(model=model,rows=rows,meta=meta,counts=counts,cases=cases,critical=critical,valid=valid,lat=lat))
 complete=all(d['meta']['status']=='completed' and len(d['valid'])==expected and not d['counts']['infrastructure'] for d in data)
 stamp=datetime.datetime.now(datetime.timezone.utc).isoformat();title='Evaluation running — no decision yet'
 if complete:title='Evaluation complete — inspect failures before selection'
 if complete and data[1]['critical']:title='Do not promote: the trained model still has critical failures'
 def score(d,id):
  rows=d['cases'].get(id,[]);return f"{sum(x['status']=='pass' for x in rows)}/{len(rows)} passed" if rows else 'Not run'
 page='''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="15"><title>Margin · LoRA results</title><style>body{margin:0;background:#f7f5ed;color:#24382c;font:16px/1.55 system-ui}main{max-width:1100px;margin:auto;padding:32px 24px}h1,h2{font-family:Georgia}h1{font-size:36px}.notice{padding:18px;background:#e9e3d1;border-left:4px solid #967329}table{width:100%;border-collapse:collapse}td,th{padding:10px;text-align:left;border-bottom:1px solid #d6dbcf}section{margin:32px 0}.muted{color:#657165;font-size:13px}a{color:#286346}details{margin:12px 0}pre{white-space:pre-wrap;overflow-wrap:anywhere}code{font-size:12px}@media(max-width:650px){table{display:block;overflow:auto}}</style><main><p>Margin / Developer model evaluation</p>'''
 page+=f'<h1>{e(title)}</h1><div class="notice">Updated {stamp}<br>Same frozen suite, 3 repetitions, one model loaded at a time. {expected} model requests per candidate. Deterministic dispatch is reported separately.</div><section><h2>1. Overall result</h2><table><tr><th>Candidate</th><th>State</th><th>Passed / tested</th><th>Critical failures</th><th>Infrastructure</th><th>Remaining</th></tr>'
 for d,label in zip(data,['Unadapted control','Trained adapter']):
  page+=f'<tr><td>{label}</td><td>{e(d["meta"]["status"])}</td><td>{d["counts"]["pass"]} / {len(d["valid"])}</td><td>{len(d["critical"])}</td><td>{d["counts"]["infrastructure"]}</td><td>{max(0,expected-len(d["valid"])-d["counts"]["infrastructure"])}</td></tr>'
 page+='</table></section><section><h2>2. The seven original failures</h2><p>Each originally failed all three repetitions. A partial 1/1 or 2/2 is not a completed fix.</p><table><tr><th>Case</th><th>Request</th><th>Control</th><th>Trained</th></tr>'
 byid={c['id']:c for c in m['cases']}
 for id in (ORIGINAL if all(x in byid for x in ORIGINAL) else list(byid)):
  c=byid.get(id,{});page+=f'<tr><td><code>{id}</code></td><td>{e(c.get("prompt","ID not found — inspect manifest"))}</td><td>{score(data[0],id)}</td><td>{score(data[1],id)}</td></tr>'
 page+='</table></section><section><h2>3. Category scores</h2><table><tr><th>Category</th><th>Control passed / tested</th><th>Trained passed / tested</th></tr>'
 for cat in sorted({c['category'] for c in m['cases'] if not c.get('direct')}):
  vals=[]
  for d in data:
   rows=[x for x in d['valid'] if x['category']==cat];vals.append(f"{sum(x['status']=='pass' for x in rows)}/{len(rows)}")
  page+=f'<tr><td>{e(cat)}</td><td>{vals[0]}</td><td>{vals[1]}</td></tr>'
 page+='</table></section><section><h2>4. New regressions against the control</h2>'
 regressions=[id for id,rows in data[0]['cases'].items() if len(rows)==3 and all(x['status']=='pass' for x in rows) and any(x['status']=='fail' for x in data[1]['cases'].get(id,[]))]
 page+=('<ul>'+''.join(f'<li><code>{e(id)}</code>: {e(byid[id]["prompt"])} — trained {score(data[1],id)}</li>' for id in regressions)+'</ul>') if regressions else '<p>None observed yet.'+('' if complete else ' Comparison is incomplete.')+'</p>'
 page+='</section><section><h2>5. Speed and sampled memory</h2><table><tr><th>Candidate</th><th>Median</th><th>p95</th><th>Process RSS peak</th></tr>'
 for d,label in zip(data,['Control','Trained']):
  lat=d['lat'];median=f'{statistics.median(lat):.2f}s' if lat else '—';p95=f'{lat[math.ceil(.95*len(lat))-1]:.2f}s' if lat else '—';rss=max((x.get('memory',{}).get('rss_bytes',0) for x in d['rows']),default=0)/1024**3
  page+=f'<tr><td>{label}</td><td>{median}</td><td>{p95}</td><td>{rss:.2f} GiB</td></tr>'
 page+='</table><p class="muted">Same Mac and runtime. These measurements do not establish behavior on a 16 GB Mac; sampled RSS is not total system memory.</p></section><section><h2>6. Evidence and limits</h2><p>This is regression evaluation of the final checkpoint. Independent adversarial holdout, checkpoint selection and consumer deployment remain separate. No app default changed.</p><p><a href="report.html">Every case and raw response</a> · <a href="manifest.json">Frozen manifest</a> · <a href="summary.json">Summary JSON</a></p></section></main></html>'
 if complete and root.name=='20260912T045552Z-final-comparison':
  assessment='<section><h2>Assessment: improved, but not ready to ship</h2><p>The pilot fixed all seven original failed cases in all three repetitions. It retained 86 of the control’s 89 fully passing cases and introduced three regressions, each failing 3/3.</p><ul><li><strong>Calendar move:</strong> omitted the destination date for “shift tomorrow’s 1:1 to Thursday”.</li><li><strong>All-day batch (critical):</strong> included all three events and correct dates, but omitted all_day=true for each. Midnight is not an all-day event.</li><li><strong>Research:</strong> gave the correct facts but omitted the required source citation.</li></ul><p>Accuracy rose from 92.71% to 96.88%; median latency improved by 20.1% and p95 by 33.1%. The 97% accuracy gate and zero-critical-failure gate are not met. The three critical failures are three repetitions of one case, not three distinct critical cases.</p><p>Next: repair training coverage for these behaviors while retaining broad rehearsal examples; freeze fresh paraphrase and adversarial holdouts before another pilot. Keep this run and its grader unchanged. Training loss alone did not predict these regressions.</p></section>'
  page=page.replace('<section><h2>2.',assessment+'<section><h2>2.',1)
 if not all(x in byid for x in ORIGINAL):
  page=page.replace('The seven original failures','Fresh development holdout').replace('Each originally failed all three repetitions. A partial 1/1 or 2/2 is not a completed fix.','Separately authored and frozen before pilot 2; three repetitions per case. This is not independent external validation.')
 (root/'comparison.html').write_text(page)
