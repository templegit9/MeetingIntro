"""One bounded actual-pixel capability probe. Does not execute tools or score the suite."""
import base64,datetime,hashlib,json,time,urllib.request,urllib.error
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]/'docs/evals/margin-vision'
def stamp():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def req(path,payload=None):
 r=urllib.request.Request('http://127.0.0.1:11434'+path,data=json.dumps(payload).encode() if payload is not None else None,headers={'Content-Type':'application/json'})
 with urllib.request.urlopen(r,timeout=60) as f:return json.load(f)
model='margin-lora-pilot:final';started=stamp();folder=ROOT/'runs'/(datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-pilot1-image-probe');folder.mkdir(parents=True,exist_ok=False)
ps=req('/api/ps')
if any(m['name']!=model for m in ps.get('models',[])):raise SystemExit('Another model is resident; no probe started')
show=req('/api/show',{'model':model});tags=req('/api/tags');asset=ROOT/'assets/diagram.png';data=asset.read_bytes()
prompt='Read this image. What is the diagram about? List the directed connections, including the failure path. If you cannot see the image, say so. Do not guess.'
payload={'model':model,'stream':False,'messages':[{'role':'user','content':prompt,'images':[base64.b64encode(data).decode()]}],'options':{'temperature':0,'num_predict':256,'num_ctx':4096},'keep_alive':0}
record={'started_at':started,'model':model,'model_metadata':next((x for x in tags['models'] if x['name']==model),{}),'capabilities':show.get('capabilities'),'runtime':req('/api/version'),'asset':'assets/diagram.png','asset_sha256':hashlib.sha256(data).hexdigest(),'prompt':prompt,'options':payload['options'],'suite_cases_scored':0,'suite_responses_not_run':114,'actual_pixels_sent':True}
t=time.monotonic()
try:
 record['response']=req('/api/chat',payload);record['status']='response_received_requires_visual_grounding_review'
except urllib.error.HTTPError as e:
 record['http_status']=e.code;record['response_body']=e.read().decode();record['status']='capability_blocked' if 'image' in record['response_body'].lower() else 'infrastructure_error'
except Exception as e:record['status']='infrastructure_error';record['error']=str(e)
record['elapsed_seconds']=time.monotonic()-t;record['finished_at']=stamp();record['residency_after']=req('/api/ps')
(folder/'probe.json').write_text(json.dumps(record,indent=2));print(json.dumps(record,indent=2));print('RESULT_DIR='+str(folder))
