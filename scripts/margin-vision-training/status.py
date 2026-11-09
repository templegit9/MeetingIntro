"""Read-only training telemetry; never loads a model or modifies the run."""
import pathlib,json,subprocess,collections,shutil
r=pathlib.Path('/mnt/c/Users/oluyi/Documents/Projects/Margin-Vision-Pilot/mixed-pilot-20260913')
def read(n):
 try:return json.loads((r/n).read_text())
 except (OSError,ValueError):return None
def rows(n):
 result=[]
 try:
  for line in (r/n).read_text().splitlines():
   try:result.append(json.loads(line))
   except ValueError:pass
 except OSError:pass
 return result
manifest=read('pilot-manifest.json');metrics=rows('metrics.jsonl')
for row in metrics:row['phase']='pilot' if manifest and row['timestamp']>=manifest['started'] else 'smoke'
training=rows('data/train.jsonl');validation=rows('data/validation.jsonl');byid={x['id']:x for x in validation}
def responses(n):
 result=rows(n)
 for row in result:
  source=byid.get(row['id'],{});row['prompt']=source.get('prompt');row['document']=source.get('document');row['image']=source.get('image')
 return result
checkpoints=[]
for name in ['smoke-adapter','pilot-checkpoint','pilot-adapter','epoch-1-adapter','epoch-2-adapter','epoch-3-adapter']:
 p=r/name
 if p.exists():
  files=[x for x in p.iterdir() if x.is_file()];checkpoints.append({'name':name,'bytes':sum(x.stat().st_size for x in files),'modified_epoch':max(x.stat().st_mtime for x in files),'files':[x.name for x in files]})
try:gpu=subprocess.check_output(['nvidia-smi','--query-gpu=memory.used,utilization.gpu','--format=csv,noheader'],text=True)
except Exception:gpu='Unavailable'
active=[]
for proc in pathlib.Path('/proc').iterdir():
 if not proc.name.isdigit():continue
 try:
  args=(proc/'cmdline').read_bytes().split(b'\0');decoded=[x.decode(errors='replace') for x in args]
  scripts=[x for x in decoded if str(r) in x and x.endswith('.py') and (pathlib.Path(x).name in ['train.py','pipeline.py'] or pathlib.Path(x).name.startswith('resume_') or pathlib.Path(x).name in ['continue_epochs.py','train_epoch_continuation.py'])]
  if scripts:active.append({'pid':int(proc.name),'script':pathlib.Path(scripts[0]).name})
 except OSError:pass
print(json.dumps({'active_workers':active,'status':read('status.json'),'dataset':read('dataset-manifest.json'),'gate':read('reload-gate.json'),'export_gate':read('export-gate.json'),'pipeline':read('pipeline.json'),'epoch_schedule':read('epoch-schedule.json'),'epoch_continuation':read('epoch-continuation-manifest.json'),'epoch_evaluations':{str(i):responses(f'epoch-{i}-responses.jsonl') for i in [1,2,3]},'pilot_manifest':manifest,'smoke_manifest':read('smoke-manifest.json'),'metrics':metrics,'checkpoints':checkpoints,'baseline':responses('baseline-responses.jsonl'),'adapted':responses('evaluate-responses.jsonl'),'categories':{cat:{split:dict(collections.Counter(x['modality'] for x in values if x['category']==cat)) for split,values in [('train',training),('validation',validation)]} for cat in sorted({x['category'] for x in training})},'disk_free_gib':{disk:shutil.disk_usage(path).free/2**30 for disk,path in [('C','/mnt/c'),('D','/mnt/d')]},'log':''.join('\nLOG '+p.name+'\n'+p.read_text()[-1800:] for p in r.glob('*.log')),'gpu':gpu}))
