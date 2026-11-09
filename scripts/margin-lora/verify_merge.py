"""Verify sampled trained tensors changed and preserved MTP tensors are exact."""
import pathlib,json,argparse
import torch
from safetensors import safe_open
p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--phase',choices=['smoke','pilot'],default='smoke');a=p.parse_args();r=pathlib.Path(a.root)
b=next((r/'cache/huggingface/hub/models--empero-ai--Qwen3.8-4B-Distill/snapshots').iterdir());m=r/f'artifacts/{a.phase}-canonical';index=json.loads((m/'model.safetensors.index.json').read_text())['weight_map']
source={}
for file in b.glob('*.safetensors'):
 with safe_open(file,framework='pt',device='cpu') as f:
  for key in f.keys():source[key]=file
sample=['model.language_model.layers.0.linear_attn.in_proj_qkv.weight','model.language_model.layers.15.mlp.down_proj.weight','model.language_model.layers.31.self_attn.q_proj.weight']
rows=[]
for key in sample+[k for k in index if k.startswith('mtp.')]:
 with safe_open(source[key],framework='pt',device='cpu') as f:x=f.get_tensor(key)
 with safe_open(m/index[key],framework='pt',device='cpu') as f:y=f.get_tensor(key)
 assert x.shape==y.shape,key
 changed=int(torch.count_nonzero(x!=y));rows.append({'tensor':key,'changed_elements':changed,'elements':x.numel()})
 if key.startswith('mtp.'):assert changed==0,key
assert all(row['changed_elements']>0 for row in rows[:len(sample)]),'Sampled trained weights did not change'
(r/f'artifacts/{a.phase}-merge-verification.json').write_text(json.dumps({'passed':True,'tensors':rows},indent=2));print('Merge verification passed:',len(sample),'changed samples;',len(rows)-len(sample),'exact MTP tensors',flush=True)
