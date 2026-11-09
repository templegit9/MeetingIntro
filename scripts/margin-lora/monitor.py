"""Read-only live training monitor. Does not load any inference model."""
import pathlib,json,time,datetime,subprocess,html,argparse
p=argparse.ArgumentParser();p.add_argument('--root',required=True);a=p.parse_args();r=pathlib.Path(a.root)
while True:
 try:
  state=json.loads((r/'status.json').read_text());metrics=[]
  if (r/'logs/metrics.jsonl').exists():
   for l in (r/'logs/metrics.jsonl').read_text().splitlines():
    try:metrics.append(json.loads(l))
    except ValueError:pass
  gpu=subprocess.check_output(['nvidia-smi','--query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu','--format=csv,noheader'],text=True).strip()
  now=datetime.datetime.now(datetime.timezone.utc).isoformat()
  with (r/'logs/gpu.jsonl').open('a') as f:f.write(json.dumps(dict(timestamp=now,gpu=gpu))+'\n')
  esc=html.escape
  body='<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><meta http-equiv="refresh" content="15"><title>Margin LoRA training</title><style>body{font:16px/1.5 system-ui;background:#f5f2e8;color:#24392f;max-width:1000px;margin:40px auto;padding:20px}h1{font-family:Georgia}table{width:100%;border-collapse:collapse}td,th{padding:8px;text-align:left;border-bottom:1px solid #ccc}pre{white-space:pre-wrap;overflow-wrap:anywhere}.note{padding:16px;background:#e4e8dc}</style><h1>Margin / Empero LoRA</h1>'
  body+=f'<p>Monitor updated {esc(now)} · State updated {esc(state.get("timestamp",""))}</p><div class="note"><strong>{esc(state["stage"])}</strong> · {esc(state.get("mode",""))}<br>{esc(gpu)}</div><p>Synthetic pilot training. Loss is not eval accuracy. No model has been promoted to the consumer app. 16 GB Mac validation remains separate.</p>'
  body+='<table><tr><th>Time UTC</th><th>Mode</th><th>Step</th><th>Loss / eval loss</th><th>Peak allocated GiB</th></tr>'
  for m in reversed(metrics[-100:]):body+=f'<tr><td>{esc(m["timestamp"])}</td><td>{esc(m["mode"])}</td><td>{m["step"]}/{m["planned_steps"]}</td><td>{esc(str(m["metrics"].get("loss",m["metrics"].get("eval_loss","—"))))}</td><td>{m["peak_allocated_bytes"]/1024**3:.2f}</td></tr>'
  body+='</table><h2>Current state</h2><pre>'+esc(json.dumps(state,indent=2))+'</pre><p>Project: C:\\Users\\oluyi\\Documents\\Projects\\Margin-Empero-LoRA</p></html>'
  tmp=r/'reports/training.tmp';tmp.write_text(body);tmp.replace(r/'reports/training.html')
  if state['stage'] in ['failed','pilot_training_complete']:break
 except Exception as error:print(str(error),flush=True)
 time.sleep(10)
