"""Restore canonical source tensor names and preserve untouched MTP tensors."""
import pathlib,json,argparse,shutil,collections,datetime
from safetensors import safe_open
from safetensors.torch import save_file
p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--phase',choices=['smoke','pilot'],default='smoke');a=p.parse_args();r=pathlib.Path(a.root)
b=next((r/'cache/huggingface/hub/models--empero-ai--Qwen3.8-4B-Distill/snapshots').iterdir());m=r/f'artifacts/{a.phase}-merged';out=r/f'artifacts/{a.phase}-canonical';out.mkdir(exist_ok=True)
base={}
for path in b.glob('*.safetensors'):
 with safe_open(path,framework='pt',device='cpu') as f:
  for key in f.keys():base[key]=path
index=json.loads((m/'model.safetensors.index.json').read_text());mapping={};seen=set();total=0
for path in m.glob('*.safetensors'):
 tensors={}
 with safe_open(path,framework='pt',device='cpu') as f:
  for old in f.keys():
   queue=[old];candidates=set();visited=set()
   while queue:
    name=queue.pop()
    if name in visited:continue
    visited.add(name)
    if name in base:candidates.add(name)
    parts=name.split('.')
    for i,part in enumerate(parts):
     if part=='language_model' or (i==0 and part=='model'):queue.append('.'.join(parts[:i]+parts[i+1:]))
   assert len(candidates)==1,(old,candidates)
   name=candidates.pop();assert name not in seen,name;seen.add(name)
   tensor=f.get_tensor(old);tensors[name]=tensor;total+=tensor.numel()*tensor.element_size();mapping[name]=path.name
 save_file(tensors,str(out/path.name),metadata={'format':'pt'});del tensors
missing=set(base)-seen
assert missing and all(k.startswith('mtp.') for k in missing),sorted(missing)
extra={}
for key in sorted(missing):
 with safe_open(base[key],framework='pt',device='cpu') as f:extra[key]=f.get_tensor(key)
 total+=extra[key].numel()*extra[key].element_size();mapping[key]='model-mtp.safetensors'
save_file(extra,str(out/'model-mtp.safetensors'),metadata={'format':'pt'})
for path in b.iterdir():
 if path.suffix in ['.json','.jinja','.txt','.model'] and 'index' not in path.name:shutil.copy2(path,out/path.name)
(out/'model.safetensors.index.json').write_text(json.dumps({'metadata':{'total_size':total},'weight_map':mapping},indent=2))
proof={'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'source_tensors':len(base),'merged_tensors':len(seen),'preserved_mtp':sorted(missing),'canonical_tensors':len(mapping),'source_and_output_keys_equal':set(mapping)==set(base)}
(r/f'artifacts/{a.phase}-canonicalization.json').write_text(json.dumps(proof,indent=2));print(json.dumps(proof),flush=True)
