"""One candidate per process. Frozen screening, no live tool execution."""
import os,json,pathlib,datetime,time,traceback,argparse,re,hashlib
p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--candidate',required=True);a=p.parse_args();root=pathlib.Path(a.root)
def now():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def state(stage,**kw):
 d=dict(timestamp=now(),candidate=a.candidate,stage=stage,**kw);tmp=root/'status.tmp';tmp.write_text(json.dumps(d));tmp.replace(root/'status.json')
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def parse(raw,truncated):
 calls=[]
 for block in re.findall(r'<tool_call>(.*?)</tool_call>',raw,re.S):
  native=re.search(r'<function=([^>]+)>(.*?)</function>',block,re.S)
  if native:
   args={}
   for key,v in re.findall(r'<parameter=([^>]+)>(.*?)</parameter>',native[2],re.S):
    try:args[key]=json.loads(v.strip())
    except ValueError:args[key]=v.strip()
   calls.append({'function':{'name':native[1],'arguments':args}})
  else:
   try:
    v=json.loads(block);calls.append({'function':v.get('function',v)})
   except ValueError:pass
 content=re.sub(r'<tool_call>.*?</tool_call>','',raw,flags=re.S)
 content=re.sub(r'<think>.*?</think>','',content,flags=re.S).strip()
 return {'done':True,'done_reason':'length' if truncated else 'stop','message':{'content':content,'tool_calls':calls}}
def shape(x):
 if isinstance(x,dict):return {k:shape(v) for k,v in x.items()}
 if isinstance(x,list):return {'type':'array','items':shape(x[0]) if x else 'string','length':'infer from image; do not omit items'}
 if isinstance(x,bool):return 'boolean'
 if isinstance(x,(int,float)):return 'number'
 return 'string or null if not visible' if x is None else 'string'
def run():
 import torch
 from PIL import Image
 from transformers import AutoProcessor,Qwen3_5ForConditionalGeneration
 from huggingface_hub import snapshot_download
 from peft import PeftModel
 from grading import grade
 from vision_grading import grade as image_grade
 m=json.loads((root/'manifest.json').read_text());assert a.candidate in m['candidates']
 for f,h in m['files'].items():assert digest(root/f)==h,f
 assert not (root/'STOP').exists(),'Stop requested'
 assert torch.cuda.mem_get_info()[0]>12*1024**3,'GPU occupied; no workload eviction'
 os.environ['HF_HOME']=m['hf_home'];os.environ['TOKENIZERS_PARALLELISM']='false'
 source=snapshot_download(m['source']['repo'],revision=m['source']['revision'],local_files_only=True)
 state('loading',completed=0,total=m['requests_per_candidate'])
 processor=AutoProcessor.from_pretrained(source)
 model=Qwen3_5ForConditionalGeneration.from_pretrained(source,dtype=torch.bfloat16,device_map={'':'cuda:0'},attn_implementation='sdpa')
 if a.candidate!='unadapted':
  adapter=pathlib.Path(m['training_root'])/(a.candidate+'-adapter')
  for f,h in m['adapter_hashes'][a.candidate].items():assert digest(adapter/f)==h,'Adapter changed'
  model=PeftModel.from_pretrained(model,str(adapter))
 model.eval();torch.manual_seed(20260913)
 language=json.loads((root/'language.json').read_text());vision=json.loads((root/'vision/suite.json').read_text())
 output=root/(a.candidate+'.jsonl');assert not output.exists(),'Refuse overwriting responses'
 completed=0
 def infer(messages,tools=None):
  kw={'tools':tools} if tools else {}
  batch=processor.apply_chat_template(messages,tokenize=True,add_generation_prompt=True,return_dict=True,return_tensors='pt',enable_thinking=False,**kw).to('cuda')
  assert batch['input_ids'].shape[-1]<=12288,'Input exceeds frozen context budget'
  with torch.inference_mode():out=model.generate(**batch,max_new_tokens=2048,max_time=120,do_sample=False)
  tokens=out[0,batch['input_ids'].shape[-1]:];raw=processor.decode(tokens,skip_special_tokens=True)
  return raw,len(tokens),'pixel_values' in batch
 def append(row):
  with output.open('a') as f:f.write(json.dumps(row)+'\n');f.flush();os.fsync(f.fileno())
 for suite,cases in [('image',vision['cases']),('language',language['cases'])]:
  for rep in range(1,4):
   offset=(rep-1)*17%len(cases)
   for c in cases[offset:]+cases[:offset]:
    if (root/'STOP').exists():raise RuntimeError('Stop requested')
    row=dict(candidate=a.candidate,suite=suite,id=c['id'],category=c['category'],repeat=rep,started_at=now(),critical=c.get('critical',c.get('severity')=='critical'))
    if c.get('direct'):
     row.update(status='deterministic',actual=c['direct'],seconds=0,finished_at=now());append(row);continue
    state('evaluating',completed=completed,total=m['requests_per_candidate'],suite=suite,case=c['id'],repeat=rep)
    t=time.monotonic()
    try:
     tools=None
     if suite=='image':
      content=[]
      for path in c['assets']:
       im=Image.open(root/'vision'/path).convert('RGB');im.thumbnail((1000,750));content.append({'type':'image','image':im})
      prompt=c['prompt']+'\nContext: '+json.dumps(c['context'])+'\nFacts output fields and types (read values from image): '+json.dumps(shape(c['expected']['facts']))
      content.append({'type':'text','text':prompt});messages=[{'role':'system','content':m['vision_system']},{'role':'user','content':content}]
     else:
      s=language['snapshot'];kind=c['kind']
      if kind=='routing':messages=[{'role':'system','content':s['system']}]+c.get('context',[])[-7:]+[{'role':'user','content':language['clock']+c['prompt']}];tools=s['tools']
      elif kind in ('research','learning'):
       system=s[kind+'_system']
       if kind=='learning':system+='\nReturn JSON matching this schema: '+json.dumps(s['learning_schema'])
       messages=[{'role':'system','content':system},{'role':'user','content':c['prompt']}]
      else:messages=[{'role':'system','content':'Answer the user accurately and concisely. Do not claim to have performed actions. Use only information supplied or stable arithmetic and timezone rules.'},{'role':'user','content':c['prompt']}]
     raw,n,pixels=infer(messages,tools);truncated=n>=2048 or time.monotonic()-t>=120
     row.update(raw=raw,tokens=n,truncated=truncated,pixels=pixels)
     if suite=='image':
      clean=re.sub(r'<think>.*?</think>','',raw,flags=re.S).strip()
      try:out=json.loads(clean)
      except ValueError:out=None
      errors=image_grade(c,out);row['actual']=out
     else:
      response=parse(raw,truncated);errors,actual=grade(c,response,language['snapshot']);row.update(actual=actual,response=response)
     if truncated and 'Output budget exhausted' not in errors:errors.append('Output budget exhausted')
     row.update(status='fail' if errors else 'pass',errors=errors)
    except Exception:row.update(status='infrastructure',error=traceback.format_exc())
    row.update(seconds=time.monotonic()-t,finished_at=now());append(row);completed+=1
    if row['status']=='infrastructure':raise RuntimeError(row['error'])
 state('candidate complete',completed=completed,total=m['requests_per_candidate'])
 (root/(a.candidate+'-complete.json')).write_text(json.dumps({'timestamp':now(),'completed':completed}))
if __name__=='__main__':
 try:run()
 except Exception:state('infrastructure failure',error=traceback.format_exc());raise
