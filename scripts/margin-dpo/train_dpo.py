"""Small reference-based DPO-LoRA preflight/pilot. No export or app promotion."""
import pathlib,json,argparse,os,datetime,time,hashlib,traceback
p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--smoke',action='store_true');a=p.parse_args();r=pathlib.Path(a.root);mode='smoke' if a.smoke else 'pilot'
os.environ['HF_HOME']=str(r/'cache/huggingface');os.environ['TOKENIZERS_PARALLELISM']='false';os.environ['WANDB_DISABLED']='true';os.environ['UNSLOTH_DISABLE_STATISTICS']='1'
def status(stage,**kw):
 d=dict(stage=stage,mode=mode,timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(),**kw);(r/'status.json').write_text(json.dumps(d,indent=2));print(json.dumps(d),flush=True)
try:
 status('importing')
 import unsloth
 from unsloth import FastLanguageModel
 import torch
 import trl.import_utils as ti
 # Optional model-merging integration is not used in this training process.
 ti.is_mergekit_available=lambda:False
 from trl import DPOTrainer,DPOConfig
 from datasets import Dataset
 from transformers import TrainerCallback
 if not a.smoke:assert json.loads((r/'artifacts/smoke-result.json').read_text())['passed'],'Smoke must pass first'
 assert torch.cuda.mem_get_info()[0]>10*1024**3,'GPU busy; no eviction'
 base=next((r/'cache/huggingface/hub/models--empero-ai--Qwen3.8-4B-Distill/snapshots').iterdir())
 status('loading_4bit_base')
 model,tok=FastLanguageModel.from_pretrained(model_name=str(base),max_seq_length=8192,dtype=torch.bfloat16,load_in_4bit=True,trust_remote_code=False)
 tok=getattr(tok,'tokenizer',tok)
 targets=sorted({n.rsplit('.',1)[-1] for n,m in model.named_modules() if '.layers.' in n and hasattr(m,'in_features') and not any(x in n for x in ['vision','visual','embed','lm_head'])});assert targets
 model=FastLanguageModel.get_peft_model(model,r=16,target_modules=targets,finetune_vision_layers=False,lora_alpha=32,lora_dropout=0,bias='none',use_gradient_checkpointing='unsloth',random_state=20260912)
 model.config.use_cache=False
 def prepare(split):
  rows=[json.loads(x) for x in (r/(split+'.jsonl')).read_text().splitlines()]
  if a.smoke:
   rows=[next(x for x in rows if x['category']==cat) for cat in ['all_day_batches','calendar_destination','research_citations','memory']]
  data=[];maxlen=0
  for row in rows:
   kw=dict(tools=row['tools'] or None,tokenize=False,enable_thinking=False)
   prompt=tok.apply_chat_template(row['prompt'],add_generation_prompt=True,**kw);d={'prompt':prompt}
   for arm in ['chosen','rejected']:
    full=tok.apply_chat_template(row['prompt']+row[arm],add_generation_prompt=False,**kw);assert full.startswith(prompt),row['id']
    length=len(tok(full,add_special_tokens=False)['input_ids']);assert length<=8192,(row['id'],length);maxlen=max(maxlen,length)
    d[arm]=full[len(prompt):].rstrip('\n').removesuffix(tok.eos_token)
   data.append(d)
  (r/f'artifacts/{mode}-{split}-tokens.json').write_text(json.dumps(dict(count=len(rows),max_tokens=maxlen,ids=[x['id'] for x in rows]),indent=2));return Dataset.from_list(data)
 train=prepare('train');val=prepare('validation')
 class Monitor(TrainerCallback):
  def on_log(self,args,state,control,logs=None,**kw):
   d=dict(step=state.global_step,planned_steps=state.max_steps,metrics=logs or {},peak_allocated=torch.cuda.max_memory_allocated())
   status('training',**d)
   with (r/'metrics.jsonl').open('a') as f:f.write(json.dumps(dict(mode=mode,**d))+'\n')
   if (r/'STOP').exists():control.should_training_stop=True;control.should_save=True
   for k,v in (logs or {}).items():
    if isinstance(v,float):assert __import__('math').isfinite(v),(k,v)
 config=DPOConfig(output_dir=str(r/f'artifacts/{mode}'),beta=0.1,learning_rate=1e-5,per_device_train_batch_size=1,per_device_eval_batch_size=1,gradient_accumulation_steps=1 if a.smoke else 8,num_train_epochs=1,max_steps=4 if a.smoke else -1,max_length=8192,max_prompt_length=6500,bf16=True,fp16=False,logging_steps=1,save_steps=12,save_total_limit=2,eval_strategy='no',report_to='none',precompute_ref_log_probs=True,use_logits_to_keep=True,gradient_checkpointing=True,remove_unused_columns=False,seed=20260912)
 (r/f'artifacts/{mode}-config.json').write_text(config.to_json_string())
 class TextDPOTrainer(DPOTrainer):
  def _prepare_dataset(self, *args, **kwargs):
   # Qwen3.5's config advertises vision, but these datasets contain text only.
   # Select the trainer's standard text tokenizer path without changing model config.
   self.is_vision_model=False
   return super()._prepare_dataset(*args, **kwargs)
 trainer=TextDPOTrainer(model=model,ref_model=None,args=config,train_dataset=train,eval_dataset=val,processing_class=tok,callbacks=[Monitor()])
 status('reference_logprobs_and_training')
 result=trainer.train();assert not (r/'STOP').exists(),'Stopped by operator'
 assert all(torch.isfinite(p).all() for n,p in model.named_parameters() if 'lora_' in n)
 target=r/f'artifacts/{mode}-adapter';model.save_pretrained(str(target));tok.save_pretrained(str(target))
 output=dict(passed=True,steps=trainer.state.global_step,metrics=result.metrics,finished=datetime.datetime.now(datetime.timezone.utc).isoformat(),peak_allocated=torch.cuda.max_memory_allocated(),script_sha256=hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest())
 (r/f'artifacts/{mode}-result.json').write_text(json.dumps(output,indent=2));status(mode+'_complete',**output)
except Exception as e:status('failed',error=str(e),traceback=traceback.format_exc());raise
