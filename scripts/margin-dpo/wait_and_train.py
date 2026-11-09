"""Wait for successful resource preflight, then train from a fresh base process."""
import pathlib,json,time,subprocess,sys
r=pathlib.Path(sys.argv[1])
for _ in range(720):
 s=json.loads((r/'status.json').read_text())
 if s.get('stage')=='failed':raise SystemExit('Preflight failed; full pilot not started')
 if s.get('stage')=='smoke_complete':break
 time.sleep(5)
else:raise SystemExit('Preflight did not complete in one hour')
proof=json.loads((r/'artifacts/smoke-result.json').read_text());assert proof['passed'] and proof['steps']==4
from safetensors import safe_open
p=r/'artifacts/smoke-adapter/adapter_model.safetensors'
with safe_open(p,framework='pt',device='cpu') as f:
 arrays=[f.get_tensor(k) for k in f.keys() if 'lora_B' in k]
 assert arrays and any((x!=0).any() for x in arrays),'No learned adapter update'
# Wait for the prior process to actually release CUDA before starting another.
for _ in range(60):
 free=int(subprocess.check_output(['nvidia-smi','--query-gpu=memory.free','--format=csv,noheader,nounits'],text=True).strip())
 if free>11000:break
 time.sleep(2)
else:raise SystemExit('GPU did not become available; no second model loaded')
subprocess.run([sys.executable,str(r/'scripts/train_dpo.py'),'--root',str(r)],check=True)
