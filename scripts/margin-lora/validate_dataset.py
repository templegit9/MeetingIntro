import pathlib,json,sys,collections,hashlib
sys.path.insert(0,str(pathlib.Path(__file__).parents[1]/'margin-model-eval'))
from grading import schema_errors
root=pathlib.Path(sys.argv[1]);snapshot=json.loads(pathlib.Path(sys.argv[2]).read_text());schemas={t['function']['name']:t['function']['parameters'] for t in snapshot['tools']}
counts=collections.Counter();tools=collections.Counter();errors=[]
for p in root.glob('*.jsonl'):
 for line in p.read_text().splitlines():
  r=json.loads(line);src=r['messages'][1]['content'];reply=r['messages'][-1];counts[r['split']]+=1
  for call in reply.get('tool_calls',[]):
   f=call['function'];tools[f['name']]+=1
   errors.extend((r['id']+': '+e) for e in schema_errors(f['arguments'],schemas[f['name']]))
   if f['name']=='move_event' and 'new_date' in f['arguments']:assert 'new_start' not in f['arguments']
  if r['category']=='memory':
   entries=json.loads(reply['content']);errors.extend(schema_errors(entries,snapshot['learning_schema']))
   for e in entries:assert e['evidence'] in src and 8<=len(e['evidence'])<=300
assert not errors,errors[:20]
review={'validated_rows':dict(counts),'tool_coverage':dict(tools),'schema_errors':errors,'limitations':['Synthetic template-based development corpus, not independently reviewed human data.','Research response grounding and multi-turn tool execution are regression-only in pilot v1.','Independent adversarial holdout still required before promotion.']}
(root/'validation-report.json').write_text(json.dumps(review,indent=2)+'\n');print(json.dumps(review))
