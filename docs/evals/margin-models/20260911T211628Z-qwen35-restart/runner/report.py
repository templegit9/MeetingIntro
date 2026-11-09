import argparse, collections, datetime, hashlib, html, json, math, pathlib, statistics

def build(root):
    root=pathlib.Path(root);manifest=json.loads((root/'manifest.json').read_text());expected=sum(not c.get('direct') for c in manifest['cases'])*manifest['repetitions']; esc=html.escape
    summaries=[];sections=[]
    for model in manifest['models']:
        key=model.replace(':','-').replace('/','-'); meta_path=root/(key+'-run.json'); log=root/(key+'.jsonl'); meta=json.loads(meta_path.read_text()) if meta_path.exists() else {'status':'not_run','reason':'Not run yet; no result inferred.'}
        rows=[]
        if log.exists():
            for line in log.read_text().splitlines():
                try: rows.append(json.loads(line))
                except ValueError: pass
        valid=[r for r in rows if r['status'] in ('pass','fail')];counts=collections.Counter(r['status'] for r in rows);lat=sorted(r['latency_seconds'] for r in valid);by_case=collections.defaultdict(list)
        for r in valid: by_case[r['id']].append(r)
        stable=sum(len(rs)==manifest['repetitions'] and all(r['status']=='pass' for r in rs) for rs in by_case.values());critical=[r for r in valid if r['status']=='fail' and (r['category'] in ('Safety boundaries','Prompt injection in context','Batch completeness') or r['id'] in ('learn-5','learn-6','learn-7'))]
        qualified=meta['status']=='completed' and len(valid)==expected and not critical
        rss=max((r.get('memory',{}).get('rss_bytes',0) for r in rows),default=0);vram=max((r.get('memory',{}).get('runtime_vram_bytes',0) for r in rows),default=0)
        fmt=lambda x: '—' if x is None else f'{x:.1f}s'
        summary={'model':model,'status':meta['status'],'valid':len(valid),'expected':expected,'pass':counts['pass'],'fail':counts['fail'],'infrastructure':counts['infrastructure'],'not_run':max(0,expected-len(valid)-counts['infrastructure']),'stable_cases':stable,'critical_failures':len(critical),'qualified':qualified,'median':statistics.median(lat) if lat else None,'p95':lat[math.ceil(.95*len(lat))-1] if lat else None,'rss_peak_bytes':rss,'runtime_vram_peak_bytes':vram};summaries.append(summary)
        header=f'<section id="{key}"><h2>{esc(model)}</h2><p><b>{esc(meta["status"])}</b> · {esc(meta.get("reason",""))}</p><p>{counts["pass"]} passed / {counts["fail"]} failed / {counts["infrastructure"]} infrastructure / {summary["not_run"]} not run. {stable} cases passed all three repetitions. {len(critical)} boundary or completeness failures.</p>'
        header+=f'<p>Median {fmt(summary["median"])} · p95 {fmt(summary["p95"])} · cold start {fmt(meta.get("cold_start_seconds"))}<br>Sampled Ollama process RSS peak {rss/1024**3:.1f} GiB · runtime-reported GPU allocation peak {vram/1024**3:.1f} GiB. These overlap; do not add them.</p>'
        header+='<table><thead><tr><th>Category</th><th>Passed</th><th>Failed</th><th>Infrastructure</th></tr></thead><tbody>'
        for category in sorted({c['category'] for c in manifest['cases'] if not c.get('direct')}):
            cs=collections.Counter(r['status'] for r in rows if r['category']==category and r['status']!='deterministic');header+=f'<tr><td>{esc(category)}</td><td>{cs["pass"]}</td><td>{cs["fail"]}</td><td>{cs["infrastructure"]}</td></tr>'
        header+='</tbody></table><h3>Cases · failures first</h3>'
        for r in sorted(rows,key=lambda r:(r['status'] not in ('fail','infrastructure'),r['id'],r['repeat'])):
            header+=f'<details class="case {r["status"]}"><summary>{esc(r["status"].upper())} · {esc(r["category"])} · repeat {r["repeat"]} · {esc(r["prompt"][:120])}</summary><p>{esc(r["scope"])}</p><p>{esc("; ".join(r.get("errors",[])) or r.get("error",""))}</p><pre>{esc(json.dumps(r,indent=2))}</pre></details>'
        header+=f'<p><a href="{key}.jsonl">Raw cases</a> · <a href="{key}-run.json">Run metadata</a></p></section>';sections.append(header)
    complete=all(s['status']=='completed' and s['valid']==expected for s in summaries)
    title='No overall winner yet' if not complete else 'Comparison completed — inspect gates before selection'
    generated=datetime.datetime.now(datetime.timezone.utc).isoformat()
    page='''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Margin model comparison</title><style>body{font:15px/1.55 system-ui;background:#f6f3e9;color:#24382d;margin:0}main{max-width:1200px;margin:auto;padding:32px 22px}h1,h2{font-family:Georgia,serif}h1{font-size:36px}section{margin-top:40px;border-top:3px solid #326647;padding-top:12px}table{width:100%;border-collapse:collapse;background:#fffdf7;display:block;overflow-x:auto}td,th{text-align:left;padding:10px;border-bottom:1px solid #dedbce;white-space:nowrap}.notice{background:#eae3cc;padding:18px;border-left:4px solid #ad862e}a{color:#22663e}details{padding:8px;border-bottom:1px solid #dedbce}summary{cursor:pointer}.fail summary,.infrastructure summary{color:#982e21}pre{white-space:pre-wrap;overflow-wrap:anywhere;max-height:500px;overflow:auto;font-size:12px}.controls{padding:12px 0;display:flex;gap:12px;flex-wrap:wrap}input{padding:8px}</style><main><p>Margin / Developer evaluation</p><h1>Which model should power Margin?</h1>'''
    page+=f'<div class="notice"><b>{title}</b><p>Frozen {esc(manifest["frozen_at"])} · Report updated {generated}</p><p>All tests are serial. Three repetitions per case. Raw prompts, exact package digests, clock and inference settings are retained. Missing or incomplete candidates cannot win.</p></div>'
    page+=f'<p>{len(manifest["cases"])} fixtures; {expected} model requests planned per candidate, excluding deterministic dispatch.</p><table><thead><tr><th>Model</th><th>Run</th><th>Pass / valid</th><th>Not run</th><th>Critical failures</th><th>Median</th><th>p95</th></tr></thead><tbody>'
    for s in summaries:
        format_time=lambda n:'—' if n is None else f'{n:.1f}s'
        page+=f'<tr><td><a href="#{s["model"].replace(":","-")}">{s["model"]}</a></td><td>{s["status"]}</td><td>{s["pass"]}/{s["valid"]}</td><td>{s["not_run"]}</td><td>{s["critical_failures"]}</td><td>{format_time(s["median"])}</td><td>{format_time(s["p95"])}</td></tr>'
    page+='</tbody></table><h2>Read the evidence correctly</h2><p>'+esc(manifest['scope'])+'</p><p>RSS is sampled process memory; GPU allocation is runtime-reported. Neither is a precise measurement of total peak unified memory. Background activity and swap are recorded. This run cannot establish performance on a different Mac or runtime. Boundary failures are unsafe model outputs, not evidence that the app executed an unauthorized action.</p><p><a href="manifest.json">Frozen suite and settings</a> · <a href="summary.json">Summary data</a></p><div class="controls"><input id="search" placeholder="Find a case…" aria-label="Find a case"><label><input id="failures" type="checkbox"> Show only failures</label></div>'
    page+=''.join(sections)+'''</main><script>function filter(){const q=document.querySelector('#search').value.toLowerCase(),f=document.querySelector('#failures').checked;document.querySelectorAll('.case').forEach(e=>{e.hidden=!e.textContent.toLowerCase().includes(q)||(f&&!e.matches('.fail,.infrastructure'));});}document.querySelector('#search').oninput=filter;document.querySelector('#failures').onchange=filter;</script></html>'''
    (root/'report.html').write_text(page);(root/'summary.json').write_text(json.dumps({'generated':generated,'complete':complete,'models':summaries},indent=2)+'\n')
    return summaries
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('directory');a=p.parse_args();build(a.directory)
