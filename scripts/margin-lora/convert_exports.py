"""Sequential BF16 conversion and Q4_K_M quantization, with hashes and phase logs."""
import pathlib,json,subprocess,datetime,hashlib,argparse,traceback,os
p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--adapted-only',action='store_true');p.add_argument('--phase',choices=['smoke','pilot'],default='smoke');a=p.parse_args();r=pathlib.Path(a.root)
py='/home/oluyi/.venvs/margin-empero-lora/bin/python';tool=r/'tools/llama.cpp';out=r/('artifacts/exports' if a.phase=='smoke' else 'artifacts/pilot-exports');out.mkdir(exist_ok=True)
def state(stage,**kw):
 d=dict(stage=stage,mode='preflight',timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(),**kw)
 t=r/'status.tmp';t.write_text(json.dumps(d,indent=2));t.replace(r/'status.json');print(json.dumps(d),flush=True)
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for chunk in iter(lambda:f.read(16*1024*1024),b''):h.update(chunk)
 return h.hexdigest()
try:
 base=next((r/'cache/huggingface/hub/models--empero-ai--Qwen3.8-4B-Distill/snapshots').iterdir())
 results=[x for x in json.loads((out/'manifest.json').read_text()) if x['name']=='base-control'] if a.adapted_only and (out/'manifest.json').exists() else []
 sources=[(a.phase+'-adapted',r/f'artifacts/{a.phase}-canonical')]
 if not a.adapted_only:sources.insert(0,('base-control',base))
 for name,source in sources:
  state('converting_'+name)
  bf=out/(name+'-BF16.gguf');q=out/(name+'-Q4_K_M.gguf')
  subprocess.run([py,str(tool/'convert_hf_to_gguf.py'),str(source),'--outfile',str(bf),'--outtype','bf16'],check=True)
  state('quantizing_'+name)
  subprocess.run([str(tool/'build/bin/llama-quantize'),str(bf),str(q),'Q4_K_M','4'],check=True)
  results.append(dict(name=name,path=str(q),bytes=q.stat().st_size,sha256=sha(q)))
  (out/'manifest.json').write_text(json.dumps(results,indent=2))
 state('exports_ready',exports=results)
except Exception as e:
 state('failed',error=str(e),traceback=traceback.format_exc());raise
