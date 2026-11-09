import pathlib,json,hashlib
r=pathlib.Path('/mnt/c/Users/oluyi/Documents/Projects/Margin-Empero-LoRA-Pilot2')
from transformers import AutoTokenizer
base=next((r/'cache/huggingface/hub/models--empero-ai--Qwen3.8-4B-Distill/snapshots').iterdir())
a=AutoTokenizer.from_pretrained(str(base));b=AutoTokenizer.from_pretrained(str(r/'artifacts/pilot-adapter'))
counts=0;issues=[]
for split in ['train','validation']:
 for line in (r/f'data/{split}.jsonl').read_text().splitlines():
  row=json.loads(line);kw=dict(tokenize=False,tools=row['tools'] or None)
  for generation in [False,True]:
   messages=row['messages'][:-1] if generation else row['messages']
   x=a.apply_chat_template(messages,add_generation_prompt=generation,**kw);y=b.apply_chat_template(messages,add_generation_prompt=generation,**kw)
   if x!=y:issues.append(dict(id=row['id'],generation=generation,defect='rendered text differs'))
   if a(x,add_special_tokens=False)['input_ids']!=b(y,add_special_tokens=False)['input_ids']:issues.append(dict(id=row['id'],generation=generation,defect='token ids differ'))
  counts+=1
result=dict(rows=counts,render_comparisons=counts*2,issues=issues,source_template_sha256=hashlib.sha256(str(a.chat_template).encode()).hexdigest(),saved_template_sha256=hashlib.sha256(str(b.chat_template).encode()).hexdigest(),cpu_only=True)
(r/'reports/saved-tokenizer-audit.json').write_text(json.dumps(result,indent=2));print(json.dumps(result))
