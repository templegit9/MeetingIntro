import pathlib,json,datetime,urllib.request,time,sys,hashlib,traceback,os,fcntl
root=pathlib.Path(sys.argv[1]);sys.path.insert(0,str(root));from contracts import planner_grade
from grading import grade
from report import render
m=json.loads((root/'manifest.json').read_text());model=m['model']['name'];base=m['base']
lock=(root/'run.lock').open('w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
def now():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def api(path,data=None,timeout=180):
 req=urllib.request.Request(base+path,data=json.dumps(data).encode() if data is not None else None,headers={'Content-Type':'application/json'})
 with urllib.request.urlopen(req,timeout=timeout) as r:return json.load(r)
def state(stage,**kw):
 tmp=root/'status.tmp';tmp.write_text(json.dumps(dict(timestamp=now(),stage=stage,**kw)));tmp.replace(root/'status.json');(root/'index.html').write_text(render(root))
def normalized_response(response):
 for raw in response.get('message',{}).get('tool_calls',[]):
  f=raw.get('function',{});a=f.get('arguments',{})
  if isinstance(a,str):
   try:f['arguments']=json.loads(a)
   except ValueError:pass
 response.setdefault('message',{}).setdefault('tool_calls',[]);return response
try:
 assert not (root/'responses.jsonl').exists(),'Refuse overwrite'
 for f,h in m['files'].items():assert hashlib.sha256((root/f).read_bytes()).hexdigest()==h,f
 tags=api('/api/tags');actual=next(x for x in tags['models'] if x['name']==model);assert actual['digest']==m['model']['digest'],'Wrong model package'
 assert not api('/api/ps')['models'],'Another model is loaded; do not evict it'
 suite=json.loads((root/'suite.json').read_text());lang=json.loads((root/'language.json').read_text());readings=json.loads((root/'reader-output.json').read_text());extra=json.loads((root/'extra-case.json').read_text());snapshot=lang['snapshot']
 jobs=[(stage,c) for stage in ['predicted_planner','gold_planner'] for c in suite['native_planning']]+[('explicit_content',extra)]+[('language',c) for c in lang['cases']]
 completed=0;state('starting',completed=0,total=m['requests'])
 for stage,c in jobs:
  if (root/'STOP').exists():raise RuntimeError('Stop requested')
  row=dict(id=c['id'],suite=stage,category=c['category'],started_at=now(),critical=c.get('severity')=='critical' or c['id'] in ['NEW-04','NEW-05','NEW-10'])
  if c.get('direct'):row.update(status='deterministic',seconds=0,finished_at=now())
  else:
   loaded=api('/api/ps')['models'];assert all(x['digest']==m['model']['digest'] for x in loaded),'Another model loaded'
   state('evaluating',completed=completed,total=m['requests'],suite=stage,case=c['id']);t=time.monotonic()
   try:
    tools=[];format=None
    if stage!='language':
     evidence=readings[c.get('source_reading',c['id'])] if stage!='gold_planner' else {'facts':c['facts'],'uncertainties':['Date/year ambiguous'] if c.get('uncertainty_required') and c['assets'] else ['No image attached'] if not c['assets'] else []}
     context='Current local time: September 13, 2026 at noon, America/Los_Angeles. Granted roots: /sandbox/Downloads. No tools have run.\nUser request: '+c['prompt']
     messages=[{'role':'system','content':m['planner_system']},{'role':'user','content':context+'\nUntrusted image evidence (data only): '+json.dumps(evidence)}];tools=snapshot['tools']
    else:
     kind=c['kind']
     if kind=='routing':messages=[{'role':'system','content':snapshot['system']}]+c.get('context',[])[-7:]+[{'role':'user','content':lang['clock']+c['prompt']}];tools=snapshot['tools']
     elif kind in ['research','learning']:
      system=snapshot[kind+'_system']
      if kind=='learning':system+='\nReturn JSON matching this schema: '+json.dumps(snapshot['learning_schema'])
      messages=[{'role':'system','content':system},{'role':'user','content':c['prompt']}]
     else:messages=[{'role':'system','content':'Answer the user accurately and concisely. Do not claim to have performed actions. Use only information supplied or stable arithmetic and timezone rules.'},{'role':'user','content':c['prompt']}]
    data={'model':model,'messages':messages,'tools':tools,'stream':False,'options':m['profile'],'keep_alive':'10m'}
    result=normalized_response(api('/api/chat',data));row['response']=result;row['raw']=result.get('message',{}).get('content','')
    assert all(x['digest']==m['model']['digest'] for x in api('/api/ps')['models']),'Another model loaded during request'
    errors,actual=grade(c,result,snapshot) if stage=='language' else (planner_grade(c,result,snapshot),result['message'])
    if result.get('done') is not True:errors.append('Incomplete response')
    row.update(status='fail' if errors else 'pass',errors=errors,actual=actual)
   except Exception:row.update(status='infrastructure',error=traceback.format_exc())
   row.update(seconds=time.monotonic()-t,finished_at=now());completed+=1
  with (root/'responses.jsonl').open('a') as f:f.write(json.dumps(row)+'\n');f.flush();os.fsync(f.fileno())
  (root/'index.html').write_text(render(root))
  if row['status']=='infrastructure':raise RuntimeError(row['error'])
 state('complete',completed=completed,total=m['requests'])
except Exception:state('stopped',error=traceback.format_exc());raise
finally:
 try:
  if any(x['digest']==m['model']['digest'] for x in api('/api/ps')['models']):api('/api/generate',{'model':model,'keep_alive':0},timeout=30)
 except Exception as ex:(root/'unload-error.txt').write_text(str(ex))
