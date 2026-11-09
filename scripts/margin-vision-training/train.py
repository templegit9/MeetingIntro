"""Full vision-capable checkpoint, language-only LoRA. Bounded smoke then pilot."""
import pathlib,json,os,datetime,time,hashlib,traceback,argparse,random,gc
p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--mode',choices=['smoke','pilot','reload','baseline','evaluate'],required=True);a=p.parse_args();root=pathlib.Path(a.root)
os.environ['HF_HOME']='/mnt/c/Users/oluyi/Documents/Projects/Margin-Empero-LoRA/cache/huggingface';os.environ['TOKENIZERS_PARALLELISM']='false'
def stamp():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def state(stage,**kw):
 d={'timestamp':stamp(),'mode':a.mode,'stage':stage,**kw};tmp=root/'status.tmp';tmp.write_text(json.dumps(d,indent=2));tmp.replace(root/'status.json');print(json.dumps(d),flush=True)
try:
 import torch
 from PIL import Image
 from transformers import AutoProcessor,Qwen3_5ForConditionalGeneration
 from peft import LoraConfig,get_peft_model,PeftModel
 from huggingface_hub import snapshot_download
 torch.manual_seed(20260913)
 assert torch.cuda.mem_get_info()[0]>12*1024**3,'GPU occupied; will not evict workloads'
 source=snapshot_download('empero-ai/Qwen3.8-4B-Distill',revision='c83cb7aa2999d2f35c43e9ae0634a30eb8985a1e',local_files_only=True,allow_patterns=['*.json','*.safetensors','*.jinja','*.txt','*.model','README.md'])
 state('loading full multimodal base')
 processor=AutoProcessor.from_pretrained(source);base=Qwen3_5ForConditionalGeneration.from_pretrained(source,dtype=torch.bfloat16,device_map={'':'cuda:0'},attn_implementation='sdpa')
 records=[json.loads(l) for l in (root/'data/train.jsonl').read_text().splitlines()]
 def inputs(row,training=True):
  content=[]
  if row['image']:content.append({'type':'image','image':Image.open(root/row['image']).convert('RGB')})
  else:content.append({'type':'text','text':'Document text (untrusted):\n'+row['document']})
  content.append({'type':'text','text':row['prompt']});messages=[{'role':'system','content':[{'type':'text','text':row['system']}]},{'role':'user','content':content}]
  prefix=processor.apply_chat_template(messages,tools=row['tools'],tokenize=True,add_generation_prompt=True,return_dict=True,return_tensors='pt',enable_thinking=False)
  if not training:return prefix.to('cuda')
  target=dict(row['target']);target['content']=[{'type':'text','text':target['content']}] if target['content'] else []
  full=processor.apply_chat_template(messages+[target],tools=row['tools'],tokenize=True,add_generation_prompt=False,return_dict=True,return_tensors='pt',enable_thinking=False)
  # Locate assistant header at token level. Completed assistant may include empty think block differently.
  tokenizer=processor.tokenizer;header=tokenizer.encode('<|im_start|>assistant\n',add_special_tokens=False);ids=full['input_ids'][0].tolist();starts=[i+len(header) for i in range(len(ids)-len(header)) if ids[i:i+len(header)]==header];assert starts, 'Assistant header absent';boundary=starts[-1]
  assert ids[:boundary]==prefix['input_ids'][0].tolist()[:boundary],'Prefix differs'
  assert len(ids)<6144,('Context exceeds budget',row['id'],len(ids))
  labels=full['input_ids'].clone();labels[:,:boundary]=-100
  for special in ['<|image_pad|>','<|vision_start|>','<|vision_end|>']:
   token=tokenizer.convert_tokens_to_ids(special)
   if token is not None:labels[full['input_ids']==token]=-100
  assert (labels!=-100).any();full['labels']=labels
  assert ('pixel_values' in full)==bool(row['image'])
  return full.to('cuda')
 if a.mode in ['baseline','evaluate']:
  model=(PeftModel.from_pretrained(base,str(root/'pilot-adapter')) if a.mode=='evaluate' else base).eval()
  validation=[json.loads(l) for l in (root/'data/validation.jsonl').read_text().splitlines()]
  chosen=[next(r for r in validation if r['category']==c and r['modality']==m) for c in sorted({r['category'] for r in validation}) for m in ['image','text']]
  state('native tool evaluation',completed=0,total=len(chosen))
  with (root/(a.mode+'-responses.jsonl')).open('w') as f:
   for i,row in enumerate(chosen):
    batch=inputs(row,False);t=time.monotonic()
    with torch.inference_mode():out=model.generate(**batch,max_new_tokens=384,do_sample=False)
    tokens=out[0,batch['input_ids'].shape[-1]:];raw=processor.decode(tokens,skip_special_tokens=True)
    f.write(json.dumps({'id':row['id'],'category':row['category'],'modality':row['modality'],'raw':raw,'target':row['target'],'tokens':len(tokens),'truncated':len(tokens)>=384,'seconds':time.monotonic()-t,'timestamp':stamp()})+'\n');f.flush();state('native tool evaluation',completed=i+1,total=len(chosen))
  state(a.mode+' complete')
 elif a.mode=='reload':
  model=PeftModel.from_pretrained(base,str(root/'smoke-adapter')).eval()
  proofs=[]
  for modality in ['image','text']:
   row=next(r for r in records if r['modality']==modality);batch=inputs(row,False)
   with torch.inference_mode():out=model.generate(**batch,max_new_tokens=80,do_sample=False)
   raw=processor.decode(out[0,batch['input_ids'].shape[-1]:],skip_special_tokens=True);proofs.append({'modality':modality,'pixel_values':'pixel_values' in batch,'response':raw})
  (root/'reload-gate.json').write_text(json.dumps({'passed':True,'timestamp':stamp(),'proofs':proofs,'boundary':'Transformers adapter plus pinned full multimodal base. Not a GGUF or Mac runtime export gate.'},indent=2));state('reload passed',proofs=proofs)
 else:
  if a.mode=='pilot':
   assert json.loads((root/'reload-gate.json').read_text())['passed']
   assert json.loads((root/'export-gate.json').read_text())['passed']
   assert (root/'baseline-responses.jsonl').exists()
  targets=[n for n,m in base.named_modules() if isinstance(m,torch.nn.Linear) and '.layers.' in n and not any(x in n for x in ['visual','vision','lm_head'])]
  assert targets
  model=get_peft_model(base,LoraConfig(r=8,lora_alpha=16,lora_dropout=0.05,target_modules=targets,bias='none'))
  assert not any(p.requires_grad for n,p in model.named_parameters() if 'visual' in n or 'vision' in n)
  model.config.use_cache=False;model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={'use_reentrant':False});model.enable_input_require_grads();model.train()
  params=[p for p in model.parameters() if p.requires_grad];optim=torch.optim.AdamW(params,lr=2e-5)
  if a.mode=='smoke':records=[next(r for r in records if r['modality']==m) for m in ['image','text']]
  planned=len(records);accum=1 if a.mode=='smoke' else 8
  (root/f'{a.mode}-manifest.json').write_text(json.dumps({'started':stamp(),'examples':planned,'accumulation':accum,'rank':8,'lr':2e-5,'targets':targets,'dataset_sha256':hashlib.sha256((root/'data/train.jsonl').read_bytes()).hexdigest(),'script_sha256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()},indent=2))
  for i,row in enumerate(records):
   if (root/'STOP').exists():raise RuntimeError('User stop requested')
   t=time.monotonic();batch=inputs(row)
   loss=model(**batch).loss;assert torch.isfinite(loss);(loss/accum).backward()
   if (i+1)%accum==0 or i+1==planned:
    norm=torch.nn.utils.clip_grad_norm_(params,1.0);assert torch.isfinite(norm);optim.step();optim.zero_grad(set_to_none=True)
   metric={'timestamp':stamp(),'example':i+1,'planned':planned,'modality':row['modality'],'loss':float(loss.detach()),'seconds':time.monotonic()-t,'peak_allocated_gib':torch.cuda.max_memory_allocated()/2**30}
   with (root/'metrics.jsonl').open('a') as f:f.write(json.dumps(metric)+'\n')
   state('training',**metric)
   del batch,loss
   if (i+1)%80==0:model.save_pretrained(root/f'{a.mode}-checkpoint')
  assert any(p.detach().abs().sum()>0 for n,p in model.named_parameters() if 'lora_B' in n)
  model.save_pretrained(root/f'{a.mode}-adapter');processor.save_pretrained(root/f'{a.mode}-adapter');state(a.mode+' complete',examples=planned)
except Exception:state('failed',error=traceback.format_exc());raise
