import pathlib,json,subprocess
r=pathlib.Path('/mnt/c/Users/oluyi/Documents/Projects/Margin-Vision-Pilot/full-eval-20260913')
def read(name):
 try:return json.loads((r/name).read_text())
 except:return None
rows=[]
if (r/'responses.jsonl').exists():
 for line in (r/'responses.jsonl').read_text().splitlines():
  try:rows.append(json.loads(line))
  except json.JSONDecodeError:pass
print(json.dumps({'status':read('status.json'),'complete':read('complete.json'),'manifest':read('manifest.json'),'responses':rows,'log_tail':(r/'run.log').read_text()[-1800:] if (r/'run.log').exists() else '', 'gpu':subprocess.check_output(['nvidia-smi','--query-gpu=memory.used,utilization.gpu','--format=csv,noheader'],text=True)}))
