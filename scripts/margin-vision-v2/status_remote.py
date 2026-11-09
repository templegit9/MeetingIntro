import pathlib,json
r=pathlib.Path('/mnt/c/Users/oluyi/Documents/Projects/Margin-Vision-Pilot/separated-20260913b')
files={}
for pattern in ['supervisor.json','status.json','*-complete.json','*.jsonl']:
 for p in r.glob(pattern):files[p.name]=p.read_text()
workers=[]
for p in pathlib.Path('/proc').iterdir():
 if not p.name.isdigit():continue
 try:
  args=(p/'cmdline').read_bytes().decode(errors='replace')
  if str(r/'worker.py') in args:workers.append(int(p.name))
 except OSError:pass
files['worker-health.json']=json.dumps({'worker_pids':workers})
print(json.dumps(files))
