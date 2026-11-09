import pathlib,json,subprocess
r=pathlib.Path('/mnt/c/Users/oluyi/Documents/Projects/Margin-Vision-Pilot')
def read(p):
 try:return json.loads((r/p).read_text())
 except:return None
print(json.dumps({'status':read('status.json'),'complete':read('complete.json'),'log_tail':(r/'probe.log').read_text()[-3500:] if (r/'probe.log').exists() else '', 'gpu':subprocess.check_output(['nvidia-smi','--query-gpu=memory.used,utilization.gpu','--format=csv,noheader'],text=True),'results':{p.parent.name:[json.loads(l) for l in p.read_text().splitlines()] for p in (r/'results').glob('*/responses.jsonl')}},indent=2))
