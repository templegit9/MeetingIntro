"""Reload the smoke adapter, verify inference, and merge into a clean BF16 base."""
import os,json,pathlib,datetime,time,traceback,argparse
p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--phase',choices=['smoke','pilot'],default='smoke');a=p.parse_args();r=pathlib.Path(a.root)
os.environ['HF_HOME']=str(r/'cache/huggingface');os.environ['TOKENIZERS_PARALLELISM']='false'
def state(stage,**kw):
 d=dict(stage=stage,mode='preflight',timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(),**kw)
 t=r/'status.tmp';t.write_text(json.dumps(d,indent=2));t.replace(r/'status.json');print(json.dumps(d),flush=True)
try:
 import torch
 from transformers import Qwen3_5ForConditionalGeneration,AutoTokenizer
 from peft import PeftModel
 base=next((r/'cache/huggingface/hub/models--empero-ai--Qwen3.8-4B-Distill/snapshots').iterdir())
 state('reloading_adapter')
 model=Qwen3_5ForConditionalGeneration.from_pretrained(str(base),dtype=torch.bfloat16,device_map='cuda',trust_remote_code=False)
 model=PeftModel.from_pretrained(model,str(r/f'artifacts/{a.phase}-adapter'));model.eval()
 tokenizer=AutoTokenizer.from_pretrained(str(r/f'artifacts/{a.phase}-adapter'))
 text=tokenizer.apply_chat_template([{'role':'user','content':'Return only this JSON object: {"ready":true}'}],tokenize=False,add_generation_prompt=True,enable_thinking=False)
 inputs=tokenizer(text,return_tensors='pt').to('cuda')
 state('checking_reloaded_inference')
 with torch.inference_mode():
  output=model.generate(**inputs,max_new_tokens=128,do_sample=False)
 decoded=tokenizer.decode(output[0,inputs['input_ids'].shape[1]:],skip_special_tokens=True)
 assert decoded.strip(),'Empty response after adapter reload'
 (r/f'artifacts/{a.phase}-reload-inference.json').write_text(json.dumps({'prompt':text,'response':decoded,'tokens':output[0].tolist()},indent=2))
 state('merging_'+a.phase+'_adapter',response=decoded)
 model=model.to('cpu');del inputs,output;torch.cuda.empty_cache()
 merged=model.merge_and_unload(safe_merge=True)
 target=r/f'artifacts/{a.phase}-merged';merged.save_pretrained(str(target),safe_serialization=True,max_shard_size='2GB');tokenizer.save_pretrained(str(target))
 import subprocess,sys
 subprocess.run([sys.executable,str(r/'scripts/canonicalize_merge.py'),'--root',str(r),'--phase',a.phase],check=True)
 state('merge_complete',merged=str(r/f'artifacts/{a.phase}-canonical'))
except Exception as e:
 state('failed',error=str(e),traceback=traceback.format_exc());raise
