"""Small synthetic preference pilot; rejects are explicit mutations, not human feedback."""
import pathlib,json,copy,random,hashlib,collections,re
repo=pathlib.Path(__file__).resolve().parents[2];out=repo/'docs/evals/margin-lora/dpo-pilot';out.mkdir(parents=True,exist_ok=False)
source=pathlib.Path('/private/tmp/margin-audit-local/data');rows=[json.loads(x) for x in (source/'train.jsonl').read_text().splitlines()];pairs=[];quotas={'all_day_batches':100,'calendar_destination':100,'research_citations':100,'memory':100,'boundaries':80,'retention':120,'timezones':40}
for cat,n in quotas.items():
 selected=[r for r in rows if r['category']==cat][:n]
 for r in selected:
  chosen=r['messages'][-1];bad=copy.deepcopy(chosen);reason=''
  if cat=='all_day_batches':
   bad['tool_calls'][0]['function']['arguments']['events'][0].pop('all_day');reason='Every explicitly all-day event must retain its all_day flag.'
  elif cat=='calendar_destination':
   a=bad['tool_calls'][0]['function']['arguments'];a['new_start']=a.pop('new_date')+'T13:00:00';reason='A date-only move must not invent a clock time.'
  elif cat=='research_citations':
   bad['content']=re.sub(r'\s*\[\d+\]','',bad['content']);reason='Source-grounded answers must carry valid citations.'
  elif cat=='memory':
   entries=json.loads(chosen['content'])
   if entries:bad['content']='[]';reason='An explicit durable allowed user preference should be retained.'
   else:
    prompt=r['messages'][1]['content'];quote=re.search(r'"([^"]{8,200})"',prompt);evidence=quote.group(1) if quote else prompt[:180]
    bad['content']=json.dumps([dict(kind='soul',key='tone',value='Adopt the style described in this task',evidence=evidence)]);reason='Quoted, temporary, secret or authority-changing content must not become a durable preference.'
  elif cat=='boundaries':
   if chosen.get('tool_calls'):bad=dict(role='assistant',content='I cannot help with this request.');reason='An allowed request should not be refused.'
   else:bad=dict(role='assistant',content='',tool_calls=[dict(type='function',function=dict(name='create_event',arguments=dict(title='Requested action',start='2027-06-01T09:00:00')))]);reason='Do not substitute unrelated provider writes for unsupported requests.'
  elif cat=='retention':
   name=bad['tool_calls'][0]['function']['name'];bad['tool_calls'][0]['function']=dict(name='list_capabilities' if name!='list_capabilities' else 'list_tasks',arguments={});reason='Preserve correct routing for previously supported tasks.'
  else:
   text=bad['content'];bad['content']=text.replace(':00',':30') if ':00' in text else text.replace(':30',':00');reason='Timezone arithmetic must preserve the exact destination time.'
  assert bad!=chosen,(cat,r['id']);pairs.append(dict(id='dpo-'+r['id'],category=cat,prompt=r['messages'][:-1],chosen=[chosen],rejected=[bad],tools=r['tools'],reason=reason,source_id=r['id']))
random.Random(20260912).shuffle(pairs)
# Validation rows are separate IDs and generated parameters, never test-set outputs.
train=[];val=[];seen=collections.Counter()
for p in pairs:
 seen[p['category']]+=1;(val if seen[p['category']]%10==0 else train).append(p)
for split,rr in [('train',train),('validation',val)]: (out/(split+'.jsonl')).write_text(''.join(json.dumps(r)+'\n' for r in rr))
(out/'data-manifest.json').write_text(json.dumps(dict(counts={'train':len(train),'validation':len(val)},categories=dict(collections.Counter(p['category'] for p in pairs)),sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.glob('*.jsonl')},review='Synthetic preference pairs with reviewed mutation rules, not human-labeled feedback. Full original eval and separately frozen holdouts are excluded from training. Development validation is not independent generalization.'),indent=2))
(out/'review-samples.json').write_text(json.dumps([next(p for p in pairs if p['category']==c) for c in quotas],indent=2));print(len(train),len(val))
