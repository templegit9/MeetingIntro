import pathlib,json,subprocess,datetime,os,traceback
r=pathlib.Path('/mnt/c/Users/oluyi/Documents/Projects/Margin-Vision-Pilot/mixed-pilot-20260913');out=pathlib.Path('/home/oluyi/projects/margin-vision-smoke-export-20260913');out.mkdir(parents=True,exist_ok=True);py='/home/oluyi/.venvs/margin-empero-lora/bin/python';ll=pathlib.Path('/mnt/c/Users/oluyi/Documents/Projects/Margin-Empero-LoRA/tools/llama.cpp')
def state(stage,**kw):
 d={'mode':'export','stage':stage,'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),**kw};(r/'status.json').write_text(json.dumps(d));print(d,flush=True)
try:
 state('building image runtime on CPU')
 subprocess.run(['/home/oluyi/.venvs/margin-empero-lora/bin/cmake','--build',str(ll/'build'),'--target','llama-mtmd-cli','-j','4'],check=True)
 image=next((r/'data').glob('train-0.png'));proj=next(out.glob('*vision-f16.gguf'))
 state('checking exported model with actual pixels on CPU')
 p=subprocess.run([str(ll/'build/bin/llama-mtmd-cli'),'-m',str(out/'language-Q4_K_M.gguf'),'--mmproj',str(proj),'--image',str(image),'-p','What is the total on this receipt?','-n','48','-ngl','0','--no-mmproj-offload'],capture_output=True,text=True,timeout=240)
 (r/'export-inference.txt').write_text(p.stdout+'\n'+p.stderr);assert p.returncode==0,p.stderr[-2000:];assert '21.50' in p.stdout,'Expected visible total absent from output'
 (r/'export-gate.json').write_text(json.dumps({'passed':True,'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'output':p.stdout,'export_root':str(out),'boundary':'Smoke-adapted Q4_K_M language GGUF plus frozen vision projector, actual receipt input in llama-mtmd-cli CPU. Not installed app or Mac memory proof.'},indent=2));state('export passed')
except Exception:state('failed',error=traceback.format_exc());raise
