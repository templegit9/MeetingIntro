"""CPU-only audit of actual chat-template targets and assistant label boundaries."""
import pathlib,json,argparse,hashlib,collections,os,re
os.environ['CUDA_VISIBLE_DEVICES']=''
p=argparse.ArgumentParser();p.add_argument('--root',required=True);a=p.parse_args();r=pathlib.Path(a.root)
from transformers import AutoTokenizer
base=next((r/'cache/huggingface/hub/models--empero-ai--Qwen3.8-4B-Distill/snapshots').iterdir());t=AutoTokenizer.from_pretrained(str(base))
counts=collections.Counter();issues=[];samples={}
for split in ['train','validation']:
 for line in (r/f'data/{split}.jsonl').read_text().splitlines():
  row=json.loads(line);m=row['messages'];kw=dict(tokenize=False,tools=row['tools'] or None)
  prompt=t.apply_chat_template(m[:-1],add_generation_prompt=True,**kw);full=t.apply_chat_template(m,add_generation_prompt=False,**kw)
  header='<|im_start|>assistant\n';boundary=prompt.rfind(header)+len(header);assert full.startswith(prompt[:boundary]);target=full[boundary:]
  enc=t(full,add_special_tokens=False,return_offsets_mapping=True);supervised=t.decode([tok for tok,(start,end) in zip(enc['input_ids'],enc['offset_mapping']) if start>=boundary])
  counts[split+'_rows']+=1
  if len(enc['input_ids'])>8192:issues.append(dict(id=row['id'],defect='context overflow'))
  for call in m[-1].get('tool_calls',[]):
   f=call['function'];args=f['arguments']
   # The rendered format may be XML-like; inspect primitive values and field names.
   def walk(value,path=''):
    if isinstance(value,dict):
     for k,v in value.items():
      if k not in target:issues.append(dict(id=row['id'],defect='field missing in rendered target',path=path+'.'+k))
      walk(v,path+'.'+k)
    elif isinstance(value,list):
     for i,v in enumerate(value):walk(v,path+f'[{i}]')
   walk(args)
   for key,value in args.items():
    match=re.search(r'<parameter='+re.escape(key)+r'>\s*(.*?)\s*</parameter>',supervised,re.S)
    if not match:issues.append(dict(id=row['id'],defect='parameter lost from supervised tokens',key=key));continue
    if isinstance(value,(dict,list)):
     try:equal=json.loads(match.group(1))==value
     except ValueError:equal=False
     counts['nested_parameters_checked']+=1
     if not equal:issues.append(dict(id=row['id'],defect='nested parameter changed',key=key))
   if f['name']=='create_events':counts['batch_targets']+=1
  if row['category']=='research_citations':
   counts['research_targets']+=1
   if '[1]' not in supervised:issues.append(dict(id=row['id'],defect='citation missing from supervised tokens'))
  if row['category']=='memory':
   counts['memory_targets']+=1
   if m[-1]['content']=='[]' and '[]' not in supervised:issues.append(dict(id=row['id'],defect='empty memory target lost'))
  cat=row['category'];samples.setdefault(cat,dict(id=row['id'],structured_target=m[-1],rendered_target=target,supervised_decoded=supervised))
result=dict(cpu_only=True,base=str(base),counts=dict(counts),issues=issues,samples=samples,template_sha256=hashlib.sha256(str(t.chat_template).encode()).hexdigest(),note='Field-presence and label-boundary audit; raw sample targets included. No inference or GPU work.')
(r/'reports/serialization-audit.json').write_text(json.dumps(result,indent=2));print(json.dumps(dict(counts=result['counts'],issue_count=len(issues),first_issues=issues[:8])))
