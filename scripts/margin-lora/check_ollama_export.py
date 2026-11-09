"""Read-only JSON/tool transport checks for one quantized export at a time."""
import pathlib,json,urllib.request,urllib.error,datetime,argparse,sys,time
p=argparse.ArgumentParser();p.add_argument('--model',required=True);p.add_argument('--snapshot',required=True);p.add_argument('--output',required=True);a=p.parse_args()
def api(path,data=None):
 q=urllib.request.Request('http://127.0.0.1:11434'+path,data=None if data is None else json.dumps(data).encode(),headers={'Content-Type':'application/json'})
 with urllib.request.urlopen(q,timeout=240) as r:return json.load(r)
s=json.loads(pathlib.Path(a.snapshot).read_text());result={'model':a.model,'started':datetime.datetime.now(datetime.timezone.utc).isoformat(),'checks':[]}
try:
 result['runtime']=api('/api/version')
 result['package']=next(x for x in api('/api/tags')['models'] if x['name']==a.model)
 assert not api('/api/ps')['models'],'Another model is loaded; do not evict it'
 tests=[('json',{'messages':[{'role':'user','content':'Return only this JSON object: {"ready":true}'}]}),('tool',{'messages':[{'role':'system','content':s['system']},{'role':'user','content':'List your capabilities.'}],'tools':s['tools']})]
 for name,body in tests:
  response=api('/api/chat',dict(model=a.model,stream=False,keep_alive='5m',options={'temperature':0,'num_ctx':8192,'num_predict':1024},**body))
  message=response.get('message',{});ok=response.get('done') and response.get('done_reason')!='length'
  if name=='json':
   try:ok=ok and json.loads(message.get('content',''))=={'ready':True}
   except ValueError:ok=False
  else:ok=ok and len(message.get('tool_calls',[]))==1 and message['tool_calls'][0]['function']['name']=='list_capabilities' and isinstance(message['tool_calls'][0]['function']['arguments'],dict)
  result['checks'].append({'name':name,'passed':bool(ok),'response':response});print(name,bool(ok),flush=True)
 result['passed']=all(x['passed'] for x in result['checks'])
except Exception as e:
 result.update(passed=False,error=str(e))
 if isinstance(e,urllib.error.HTTPError):result['error_body']=e.read().decode(errors='replace')
finally:
 try:api('/api/generate',{'model':a.model,'keep_alive':0})
 except Exception as e:result['unload_error']=str(e)
 result['finished']=datetime.datetime.now(datetime.timezone.utc).isoformat();pathlib.Path(a.output).write_text(json.dumps(result,indent=2)+'\n')
 if not result.get('passed'):sys.exit(1)
