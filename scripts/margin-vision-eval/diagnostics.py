"""Secondary diagnostics only: do not change the frozen strict contract score."""
import json,re

def inspect(case,row):
 raw=row.get('raw_response','');obj=row.get('output');wrapper='plain_json'
 if not isinstance(obj,dict):
  m=re.fullmatch(r'\s*```(?:json)?\s*\n?(.*?)\n?```\s*',raw,re.S)
  if m:
   try:obj=json.loads(m.group(1));wrapper='markdown_fenced_json'
   except json.JSONDecodeError:pass
 if not isinstance(obj,dict):return {'format':'unparseable','facts_eligible':bool(case['expected']['facts']),'facts_exact':False,'plan_exact':False}
 # These exact checks intentionally stay distinct from semantic/human review.
 from eval import matches
 exp=case['expected'];eligible=bool(exp['facts'])
 return {'format':wrapper,'facts_eligible':eligible,'facts_exact':eligible and matches(exp['facts'],obj.get('facts')),'plan_exact':all(k in obj and matches(v,obj[k]) for k,v in exp.items() if k!='facts'),'decoded':obj}
