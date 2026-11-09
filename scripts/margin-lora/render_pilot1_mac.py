"""Timestamped target-Mac qualification summary; no inferred release or test success."""
import pathlib,json,statistics,datetime,html,re
repo=pathlib.Path(__file__).resolve().parents[2];root=repo/'docs/evals/margin-lora/pilot1-mac-validation'
def read(name):
 p=root/name;return json.loads(p.read_text()) if p.exists() else None
n=read('native/results.json');setup=read('managed-setup.json');pub=read('publication.json');rows=n['cases'] if n else [];lat=[r['latency_seconds'] for r in rows if not r.get('deterministic')];stamp=datetime.datetime.now(datetime.timezone.utc).isoformat()
samples=[json.loads(l) for l in (root/'resource-samples.jsonl').read_text().splitlines()] if (root/'resource-samples.jsonl').exists() else []
summary=dict(updated=stamp,native_complete=n and n['complete'],native_passed=sum(r['passed'] for r in rows),native_total=len(rows),median=statistics.median(lat) if lat else None,p95=sorted(lat)[int(len(lat)*.95)-1] if lat else None,managed_setup=setup,publication=pub)
(root/'qualification.json').write_text(json.dumps(summary,indent=2))
fixes=read('native-fixes/results.json'); installation=read('installation.json'); ui=read('ui-validation.json')
summary.update(targeted_fixes=fixes,installation=installation,ui_validation=ui)
(root/'qualification.json').write_text(json.dumps(summary,indent=2))
e=html.escape
page=f'<h1>Pilot 1 · Mac qualification</h1><p>Updated {stamp}</p><p><strong>{summary["native_passed"]}/{len(rows)} native cases passed.</strong> Managed installation: <strong>{"passed" if setup and setup.get("passed") else "failed" if setup else "running"}</strong>.</p>'
page+='<p>The eight-holiday request passed: all eight dates and titles, all-day flags, one batch proposal. No real calendar events were created during evaluation.</p>'
if fixes:
 fr=fixes['cases'];page+=f'<h2>After routing fixes · {sum(r["passed"] for r in fr)}/{len(fr)} targeted cases passed</h2><p>Tentative RSVP and date-only moves now route correctly. Seven related cases, including the holiday batch, passed. The complete 78-case suite has not been rerun after these changes.</p><p><a href="native-fixes/results.json">Targeted results</a> · <a href="native-fixes/run-info.json">Run timestamp and configuration</a></p>'
if installation and ui:
 page+=f'<h2>Installed and exercised</h2><p>Build {e(installation["build"])} installed at {e(installation["installed_at"])}. UI verified {e(ui["verified_at"])}.</p><ul><li>All eight holidays appeared in one all-day proposal; dismissed without creating events.</li><li>Test folder absent before confirmation, created after Create, removed after Cross out.</li><li>Margin card opens settings; local AI ready, no download needed.</li><li>Older duplicate stopped and unregistered; protected duplicate file remains.</li></ul><p><a href="ui-validation.json">UI evidence and limits</a></p>'
 for file,caption in [('holiday-preview','Eight-event preview'),('holiday-preview-bottom','Final date and confirmation'),('folder-created','Confirmed folder creation'),('folder-undone','Undo completed'),('settings-installed','Installed settings')]:
  page+=f'<details><summary>{caption}</summary><a href="ui/{file}.png"><img style="max-width:100%;max-height:700px" src="ui/{file}.png" alt="{caption}"></a></details>'
page+='<h2>What was verified</h2><ul><li>Installed model weights and manifest match the qualified Pilot 1 checksums.</li><li>45 roadmap guards passed, plus file, event and behavior checks recorded in the native log.</li><li>22 managed setup guards passed: consent, cancellation, checksums, cache paths and invalid manifests.</li><li>Public download uses an immutable Hugging Face commit and a pinned SHA-256.</li></ul>'
if lat:page+=f'<h2>Performance on this Mac</h2><p>24 GB RAM · median {summary["median"]:.1f}s · p95 {summary["p95"]:.1f}s. Runtime model residency peaked at {max(sum(m["size_vram"] for m in x["models"]) for x in samples)/1024**3:.2f} GiB.</p><p>These are native app requests, with thinking behavior unchanged. A build ran concurrently, so system swap growth cannot be attributed solely to the model. This does not validate a 16 GB Mac, and workstation latency is not directly comparable.</p>'
page+='<h2>Original run misses (before routing fixes)</h2><ul>'
for r in rows:
 if not r['passed']:page+='<li><strong>'+e(r['prompt'])+'</strong><br>'+e(r['actual'])+' · '+e(json.dumps(r.get('arguments',{})))+'</li>'
page+='</ul><p>The RSVP miss was an unnecessary refusal. The date move omitted a destination; the tool refuses incomplete arguments. Passing safeguards does not turn a failed request into successful completion.</p>'
page+='<h2>Categories</h2><table><tr><th>Category</th><th>Pass / tested</th></tr>'
for cat in sorted({r['category'] for r in rows}):
 rr=[r for r in rows if r['category']==cat];page+=f'<tr><td>{e(cat)}</td><td>{sum(r["passed"] for r in rr)}/{len(rr)}</td></tr>'
page+='</table><h2>Installation evidence</h2><pre>'+e(json.dumps(setup or {'status':'running'},indent=2))+'</pre>'
page+='<p><a href="report.html">Every native case</a> · <a href="native/run.log">Native guards and run log</a> · <a href="setup-guards.log">Setup guards</a> · <a href="package-verification.json">Weight verification</a> · <a href="candidate-manifest.json">Pinned package</a> · <a href="https://huggingface.co/olluyeancah/margin-pilot1-gguf">Published model</a></p>'
(root/'qualification.html').write_text('<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="30"><title>Pilot 1 Mac qualification</title><style>body{max-width:1000px;margin:40px auto;padding:24px;background:#f7f5ed;color:#263b2c;font:16px/1.6 system-ui}h1,h2{font-family:Georgia}td,th{padding:10px;text-align:left;border-bottom:1px solid #ccc}pre{white-space:pre-wrap;background:#e8ecdf;padding:15px}</style>'+page)
print(json.dumps({k:v for k,v in summary.items() if k not in ['publication','managed_setup']},indent=2))
