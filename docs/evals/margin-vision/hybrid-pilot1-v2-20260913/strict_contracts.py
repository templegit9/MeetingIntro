"""Separate image facts from native planning. No tool execution."""
import re,json,copy
from grading import schema_errors
from vision_grading import matches

def decode(raw):
 text=re.sub(r'<think>.*?</think>','',raw,flags=re.S).strip()
 match=re.fullmatch(r'```(?:json)?\s*([\s\S]*?)\s*```',text)
 if match:text=match[1]
 try:return json.loads(text),bool(match)
 except ValueError:return None,bool(match)

def shape(value):
 if isinstance(value,dict):return {'type':'object','properties':{k:shape(v) for k,v in value.items()},'required':list(value)}
 if isinstance(value,list):
  if not value:return {'type':'array','items':{'type':'string'}}
  # Table rows are heterogeneous tuples; do not infer every cell from the label column.
  if isinstance(value[0],list):return {'type':'array','items':{'type':'array','prefixItems':[shape(v) for v in value[0]],'minItems':len(value[0]),'maxItems':len(value[0])}}
  return {'type':'array','items':shape(value[0])}
 if isinstance(value,bool):return {'type':'boolean'}
 if isinstance(value,(int,float)):return {'type':'number'}
 if value is None:return {'type':['number','null']}
 return {'type':'string'}

def reader_grade(case,raw):
 obj,fenced=decode(raw);errors=[]
 if not isinstance(obj,dict) or not isinstance(obj.get('facts'),dict):return ['Invalid facts object'],obj
 actual=copy.deepcopy(obj['facts']);expected=case['facts'];id=case['id']
 if not isinstance(obj.get('uncertainties'),list):errors.append('Missing uncertainties list')
 if case.get('must_be_empty') and actual:errors.append('Invented facts without readable evidence')
 if case.get('uncertainty_required') and not obj.get('uncertainties'):errors.append('Missing explicit uncertainty')
 for k in ['edges','added_edges','removed_edges']:
  if isinstance(actual.get(k),list):actual[k]=[re.sub(r'\s*(?:->|→)\s*','->',re.sub(r'\s*\(on failure\)$','',v)) if isinstance(v,str) else v for v in actual[k]]
 if id in ['IMG-001','IMG-032','IMG-035'] and re.fullmatch(r'order processing(?: (?:architecture|workflow))?(?: diagram)?',str(actual.get('subject','')).lower()):actual['subject']='order processing'
 if id=='IMG-018' and actual.get('date')=='October 20, 2026':actual['date']='2026-10-20'
 if id=='IMG-014' and isinstance(actual.get('owners'),dict):actual['owners']=list(actual['owners'])
 if id in ['IMG-008','IMG-012'] and isinstance(actual.get('rows'),list) and actual['rows'] and actual['rows'][0]==['MONTH','REVENUE USD','COST USD']:actual['rows']=actual['rows'][1:]
 for key in ['components','query_terms']:
  if key in expected and isinstance(actual.get(key),list) and all(v in actual[key] for v in expected[key]):actual[key]=expected[key]
 if not matches(expected,actual):errors.append('Annotated facts differ')
 return errors,obj

def planner_grade(case,response,snapshot):
 calls=response['message']['tool_calls'];text=response['message']['content'];errors=[];schema={x['function']['name']:x['function']['parameters'] for x in snapshot['tools']}
 if response.get('done_reason')=='length':errors.append('Output budget exhausted')
 expected=case.get('tool')
 if expected:
  if len(calls)!=1 or calls[0]['function'].get('name')!=expected:errors.append('Wrong native tool selection')
  else:
   args=calls[0]['function']['arguments'];errors+=schema_errors(args,schema[expected])
   if not isinstance(args,dict):return errors
   allowed=set(schema[expected].get('properties',{}));errors += ['Unknown native argument '+k for k in args if k not in allowed]
   for k,v in case.get('arguments',{}).items():
    if not matches(v,args.get(k)):errors.append('Wrong argument '+k)
   for k,pattern in case.get('argument_patterns',{}).items():
    if not isinstance(args.get(k),str) or not re.search(pattern,args[k]):errors.append('Wrong argument '+k)
   if expected=='create_events':
    for e in args.get('events',[]):
     if isinstance(e,dict) and set(e)-set(schema[expected]['properties']['events']['items']['properties']):errors.append('Unknown event argument')
 else:
  if calls:errors.append('Unexpected tool call')
  if not text:errors.append('Missing grounded answer or clarification')
 for pattern in case.get('answer_patterns',[]):
  if not re.search(pattern,text):errors.append('Missing answer requirement '+pattern)
 # Never count plausible fake completion as a successful plan.
 if re.search(r'(?i)\b(?:I have|I.ve|successfully)\s+(?:created|saved|deleted|moved|searched|found)\b',text):errors.append('Unsupported completion claim')
 return errors
