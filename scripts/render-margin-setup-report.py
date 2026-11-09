#!/usr/bin/env python3
"""Snapshot setup evidence without mixing it into model routing scores."""
import argparse, hashlib, html, json, pathlib, shutil
from datetime import datetime, timezone
p=argparse.ArgumentParser(); p.add_argument('app'); p.add_argument('guards'); p.add_argument('runtime'); p.add_argument('output'); a=p.parse_args()
now=datetime.now(timezone.utc); out=pathlib.Path(a.output); out.mkdir(parents=True,exist_ok=False)
app=pathlib.Path(a.app); guard_file=pathlib.Path(a.guards); runtime=json.loads(pathlib.Path(a.runtime).read_text())
guards=[{'name':line.split(' · ',1)[1], 'pass':line.startswith('PASS')} for line in guard_file.read_text().splitlines() if line.startswith(('PASS · ','FAIL · '))]
binary=hashlib.sha256((app/'Contents/MacOS/MeetingIntro').read_bytes()).hexdigest()
evidence={'recorded_utc':now.isoformat(),'recorded_local':now.astimezone().isoformat(),'binary_sha256':binary,'guards_recorded_utc':datetime.fromtimestamp(guard_file.stat().st_mtime,timezone.utc).isoformat(),'guards':guards,'runtime':runtime,'limits':['Full first-time 14 GB model pull on a clean Mac has not been run.','First-enable popup interaction has not been exercised with fresh native preferences.','These setup checks do not rerun or replace the model routing evaluation.']}
(out/'setup-evidence.json').write_text(json.dumps(evidence,indent=2)+'\n'); shutil.copyfile(guard_file,out/'guards.log'); shutil.copyfile(a.runtime,out/'runtime.json')
esc=html.escape
def section(title,rows):
    passed=sum(r['pass'] for r in rows)
    return f'<section><h2>{esc(title)} <small>{passed}/{len(rows)} passed</small></h2><table><thead><tr><th>Check</th><th>Result</th></tr></thead><tbody>'+''.join(f'<tr><td>{esc(r["name"])}</td><td class="{ "pass" if r["pass"] else "fail" }">{ "Pass" if r["pass"] else "Fail" }</td></tr>' for r in rows)+'</tbody></table></section>'
page='''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Margin · Local setup checks</title><style>body{background:#f7f4ea;color:#233c2d;font:16px/1.6 system-ui;margin:0}main{max-width:1000px;margin:auto;padding:40px 24px}h1,h2{font-family:Georgia,serif}h1{font-size:36px}h2{margin-top:32px}small{font:14px system-ui;color:#59665e}table{width:100%;border-collapse:collapse;background:#fffdf7}th,td{text-align:left;padding:10px 14px;border-bottom:1px solid #ddd8ca}.pass{color:#247244}.fail{color:#9c3229}.notice{border-left:4px solid #bb8a3c;padding:14px 20px;background:#f0e7d6}a{color:#26734b}code{overflow-wrap:anywhere;font-size:12px}</style><main><p>Margin / Developer verification</p><h1>Local AI setup checks</h1>'''
page+=f'<p>Recorded {esc(evidence["recorded_local"])}<br><small>UTC: {esc(evidence["recorded_utc"])}</small></p><p>Option A: Meet Margin, download expectations, Not now / Prepare Margin.</p>'
page+='<div class="notice"><strong>What this establishes</strong><p>Consent and progress guards, plus actual startup and shutdown of the pinned engine in an isolated folder. No model was pulled during lifecycle checks.</p><strong>Still unverified</strong><ul>'+''.join('<li>'+esc(x)+'</li>' for x in evidence['limits'])+'</ul></div>'
page+=section('Consent, compatibility and download progress',guards)+section('Actual engine lifecycle',runtime['checks'])
page+=f'<p>Lifecycle run: {esc(runtime["started"])} → {esc(runtime["ended"])}</p><h2>Evidence</h2><p><a href="setup-evidence.json">Structured results</a> · <a href="guards.log">Guard output</a> · <a href="runtime.json">Runtime checks</a></p><p>App binary SHA-256<br><code>{binary}</code></p></main></html>'
(out/'report.html').write_text(page)
print(out/'report.html')
