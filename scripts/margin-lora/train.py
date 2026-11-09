"""BF16 LoRA pilot with explicit label masks, resource logs and recoverable checkpoints."""
import os,pathlib,json,time,datetime,argparse,subprocess,traceback,hashlib
p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--mode',choices=['smoke','pilot'],required=True);p.add_argument("--resume",default=None);a=p.parse_args()
root=pathlib.Path(a.root);os.environ['HF_HOME']=str(root/'cache/huggingface');os.environ['WANDB_DISABLED']='true';os.environ['TOKENIZERS_PARALLELISM']='false'
os.environ['UNSLOTH_DISABLE_STATISTICS']='1'
start=time.monotonic()
def stamp():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def state(stage,**kw):
 d=dict(stage=stage,mode=a.mode,timestamp=stamp(),elapsed_seconds=time.monotonic()-start);d.update(kw)
 temp=root/'status.tmp';temp.write_text(json.dumps(d,indent=2)+'\n');temp.replace(root/'status.json');print(json.dumps(d),flush=True)
def gpu():
 try:return subprocess.check_output(['nvidia-smi','--query-gpu=timestamp,name,memory.used,memory.total,utilization.gpu,temperature.gpu','--format=csv,noheader'],text=True).strip()
 except Exception:return 'unavailable'
try:
 if a.mode=='pilot':
  gate=json.loads((root/'artifacts/export-gate.json').read_text())
  assert gate.get('passed') is True,'Export/reload gate has not passed'
 provenance={'started':stamp(),'mode':a.mode,'script_sha256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),'dataset_sha256':{split:hashlib.sha256((root/f'data/{split}.jsonl').read_bytes()).hexdigest() for split in ['train','validation','holdout']}}
 (root/f'artifacts/{a.mode}-provenance.json').write_text(json.dumps(provenance,indent=2))
 state('importing',gpu=gpu())
 import unsloth
 from unsloth import FastLanguageModel
 import torch
 from transformers import Trainer,TrainingArguments,TrainerCallback,DataCollatorForSeq2Seq
 from datasets import Dataset
 from huggingface_hub import HfApi,snapshot_download
 assert torch.cuda.is_available(),'CUDA not available'
 free,total=torch.cuda.mem_get_info();assert free>10*1024**3,'Less than 10 GiB GPU free; do not evict other workloads'
 model_id='empero-ai/Qwen3.8-4B-Distill';pinfile=root/'artifacts/base-revision.json'
 if pinfile.exists():revision=json.loads(pinfile.read_text())['revision']
 else:
  revision=HfApi().model_info(model_id).sha
  pinfile.write_text(json.dumps(dict(model=model_id,revision=revision,created=stamp()),indent=2)+'\n')
 state('downloading_base',revision=revision,gpu=gpu())
 local=snapshot_download(model_id,revision=revision,allow_patterns=['*.json','*.safetensors','*.jinja','*.txt','*.model','README.md'],ignore_patterns=['optimizer*'])
 state('loading_bf16',base=local,gpu=gpu())
 model,tokenizer=FastLanguageModel.from_pretrained(model_name=local,max_seq_length=8192,dtype=torch.bfloat16,load_in_4bit=False,load_in_16bit=True,full_finetuning=False,trust_remote_code=False)
 tokenizer=getattr(tokenizer,"tokenizer",tokenizer)
 if tokenizer.pad_token_id is None:tokenizer.pad_token=tokenizer.eos_token
 # Resolve adapters against real language-layer names; exclude visual/embedding/head components.
 selected=[]
 for name,module in model.named_modules():
  if isinstance(module,torch.nn.Linear) and '.layers.' in name and not any(s in name for s in ['visual','vision','embed','lm_head']):selected.append(name)
 assert selected,'No language linear modules found'
 (root/'artifacts/adapter-targets.json').write_text(json.dumps(selected,indent=2)+'\n')
 model=FastLanguageModel.get_peft_model(model,r=16,target_modules=sorted({n.rsplit(".",1)[-1] for n in selected}),finetune_vision_layers=False,lora_alpha=32,lora_dropout=0.05,bias='none',use_gradient_checkpointing='unsloth',random_state=20260912)
 model.config.use_cache=False
 if hasattr(model.config,'text_config'):model.config.text_config.use_cache=False
 trainable,total_params=model.get_nb_trainable_parameters();state('tokenizing',trainable_parameters=trainable,total_parameters=total_params,gpu=gpu())
 def prepare(split):
  records=[json.loads(l) for l in (root/f'data/{split}.jsonl').read_text().splitlines()]
  if a.mode=='smoke':
   # Stratified short preflight covering every task type, retaining actual full schemas.
   chosen=[]
   for cat in ['boundaries','memory','calendar_arguments','calendar_intent','timezones','retention']:
    chosen.extend([r for r in records if r['category']==cat][:6])
   records=chosen[:32]
  examples=[];lengths=[];masked=[]
  for r in records:
   messages=r['messages'];kwargs=dict(tokenize=False,tools=r['tools'] or None)
   prompt_text=tokenizer.apply_chat_template(messages[:-1],add_generation_prompt=True,**kwargs)
   full_text=tokenizer.apply_chat_template(messages,add_generation_prompt=False,**kwargs)
   # Mask through the final assistant header. Generation adds an open think tag,
   # while completed messages render an empty think block with different spacing.
   header='<|im_start|>assistant\n'
   boundary=prompt_text.rfind(header)+len(header)
   assert header in prompt_text and full_text.startswith(prompt_text[:boundary]),('Chat template prefix mismatch',r['id'])
   encoded=tokenizer(full_text,add_special_tokens=False,return_offsets_mapping=True)
   full=encoded['input_ids'];offsets=encoded['offset_mapping']
   assert len(full)<=8192,('Full example exceeds context; no truncation allowed',r['id'],len(full))
   labels=[token if begin>=boundary else -100 for token,(begin,end) in zip(full,offsets)]
   prefix=[token for token,label in zip(full,labels) if label==-100]
   assert any(x!=-100 for x in labels),'No supervised tokens'
   examples.append(dict(input_ids=full,attention_mask=[1]*len(full),labels=labels));lengths.append(len(full));masked.append(len(prefix))
  (root/f'artifacts/{a.mode}-{split}-tokenization.json').write_text(json.dumps(dict(count=len(examples),min_tokens=min(lengths),max_tokens=max(lengths),mean_tokens=sum(lengths)/len(lengths),prefix_masked=True,ids=[r['id'] for r in records]),indent=2)+'\n')
  return Dataset.from_list(examples)
 train=prepare('train');validation=prepare('validation')
 # Keep pilot loss monitoring inexpensive; full output-based validation follows training.
 validation=validation.select(range(min(len(validation),32)))
 config=dict(output_dir=str(root/f'artifacts/{a.mode}'),learning_rate=5e-5,per_device_train_batch_size=1,per_device_eval_batch_size=1,gradient_accumulation_steps=1 if a.mode=='smoke' else 16,num_train_epochs=1,max_steps=20 if a.mode=='smoke' else -1,bf16=True,fp16=False,prediction_loss_only=True,eval_accumulation_steps=1,logging_steps=1,save_steps=10,save_total_limit=3,eval_strategy='steps',eval_steps=10 if a.mode=='smoke' else 25,warmup_ratio=0.03,weight_decay=0.01,lr_scheduler_type='linear',report_to='none',seed=20260912,data_seed=20260912,dataloader_num_workers=0,remove_unused_columns=False,optim='adamw_torch',max_grad_norm=1.0)
 (root/f'artifacts/{a.mode}-config.json').write_text(json.dumps(config,indent=2)+'\n')
 class Monitor(TrainerCallback):
  def on_train_begin(self,args,s,control,**kw):
   state('training',step=s.global_step,planned_steps=s.max_steps,gpu=gpu())
  def on_evaluate(self,args,s,control,**kw):
   import gc
   gc.collect();torch.cuda.empty_cache()
  def on_log(self,args,s,control,logs=None,**kw):
   row=dict(timestamp=stamp(),mode=a.mode,step=s.global_step,planned_steps=s.max_steps,gpu=gpu(),peak_allocated_bytes=torch.cuda.max_memory_allocated(),peak_reserved_bytes=torch.cuda.max_memory_reserved(),metrics=logs or {})
   with (root/'logs/metrics.jsonl').open('a') as f:f.write(json.dumps(row)+'\n')
   state('training',**row)
   if (root/'STOP').exists():control.should_training_stop=True;control.should_save=True
   for key in ('loss','eval_loss','grad_norm'):
    if logs and key in logs and not __import__('math').isfinite(logs[key]):raise RuntimeError('Non-finite '+key)
 trainer=Trainer(model=model,args=TrainingArguments(**config),train_dataset=train,eval_dataset=validation,data_collator=DataCollatorForSeq2Seq(tokenizer=tokenizer,padding=True,label_pad_token_id=-100),callbacks=[Monitor()])
 state('training',step=0,gpu=gpu());result=trainer.train(resume_from_checkpoint=a.resume)
 if (root/'STOP').exists():raise RuntimeError('User stop requested')
 target=root/f'artifacts/{a.mode}-adapter';model.save_pretrained(str(target));tokenizer.save_pretrained(str(target))
 # Retain tensor-level proof of a nontrivial adapter and finite parameters.
 adapter_params=[p.detach() for n,p in model.named_parameters() if 'lora_' in n]
 assert all(torch.isfinite(p).all().item() for p in adapter_params),'Non-finite adapter weights'
 assert any(p.abs().sum().item()>0 for n,p in model.named_parameters() if 'lora_B' in n),'Adapter has not updated'
 (root/f'artifacts/{a.mode}-result.json').write_text(json.dumps(dict(metrics=result.metrics,steps=trainer.state.global_step,peak_gpu_allocated_bytes=torch.cuda.max_memory_allocated(),peak_gpu_reserved_bytes=torch.cuda.max_memory_reserved(),adapter=str(target),finished=stamp()),indent=2)+'\n')
 state('smoke_complete' if a.mode=='smoke' else 'pilot_training_complete',step=trainer.state.global_step,adapter=str(target),gpu=gpu())
except Exception as error:
 state('failed',error=str(error),traceback=traceback.format_exc(),gpu=gpu());raise
