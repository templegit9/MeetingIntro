#!/usr/bin/env python3
"""One model at a time, append-only results, exact digests, no fallback or provider writes."""
import argparse, datetime, hashlib, json, pathlib, subprocess, sys, time, urllib.request, urllib.error, statistics, shutil, threading, re, os
from grading import grade
from fixtures import CLOCK

def now(): return datetime.datetime.now(datetime.timezone.utc).isoformat()
def api(base,path,data=None,timeout=120):
    req=urllib.request.Request(base+path, data=None if data is None else json.dumps(data).encode(),headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=timeout) as r: return json.load(r)
def swap():
    try:
        output=subprocess.check_output(['sysctl','-n','vm.swapusage'],text=True)
        return float(re.search(r'used = ([\d.]+)M',output)[1])*1024**2
    except Exception: return None

def payload(case,manifest,model):
    snapshot=manifest['snapshot']; kind=case['kind']
    if kind=='routing': messages=[{'role':'system','content':snapshot['system']}]+case.get('context',[])[-7:]+[{'role':'user','content':CLOCK+case['prompt']}]
    elif kind=='research': messages=[{'role':'system','content':snapshot['research_system']},{'role':'user','content':case['prompt']}]
    elif kind=='learning': messages=[{'role':'system','content':snapshot['learning_system']},{'role':'user','content':case['prompt']}]
    else: messages=[{'role':'system','content':'Answer the user accurately and concisely. Do not claim to have performed actions. Use only information supplied or stable arithmetic and timezone rules.'},{'role':'user','content':case['prompt']}]
    data={'model':model,'stream':False,'messages':messages,'tools':snapshot['tools'] if kind=='routing' else [],'options':manifest['profile'],'keep_alive':'10m'}
    if kind=='learning': data['format']=snapshot['learning_schema']
    return data

def main():
    p=argparse.ArgumentParser();p.add_argument('directory');p.add_argument('--model',required=True);p.add_argument('--base',default='http://127.0.0.1:11434');a=p.parse_args()
    root=pathlib.Path(a.directory);raw=(root/'manifest.json').read_bytes();manifest=json.loads(raw);fingerprint=hashlib.sha256(raw).hexdigest()
    assert fingerprint==(root/'manifest.sha256').read_text().strip(),'Manifest changed'
    for filename,sha in manifest['code_sha256'].items():
        assert hashlib.sha256(pathlib.Path(__file__).with_name(filename).read_bytes()).hexdigest()==sha,'Harness changed: '+filename
    model=a.model; assert model in manifest['models']
    key=model.replace(':','-').replace('/','-');log=root/(key+'.jsonl');meta_path=root/(key+'-run.json')
    if meta_path.exists(): raise SystemExit('Existing run cannot be overwritten; freeze a new run or inspect the incomplete result.')
    metadata={'model':model,'started':now(),'manifest_sha256':fingerprint,'host':subprocess.check_output(['hostname'],text=True).strip(),'memory_bytes':int(subprocess.check_output(['sysctl','-n','hw.memsize'])),'runtime':api(a.base,'/api/version'),'profile':manifest['profile'],'status':'running'}
    def save(): meta_path.write_text(json.dumps(metadata,indent=2)+'\n')
    installed={m['name']:m for m in api(a.base,'/api/tags')['models']}
    if model not in installed:
        metadata.update(status='blocked',reason='Exact model package is not installed; no fallback');save();return
    metadata['package']=installed[model]; metadata['swap_start_bytes']=swap();save()
    # The user explicitly asked for no simultaneous loaded models.
    def unload():
        for loaded in api(a.base,'/api/ps')['models']:
            api(a.base,'/api/generate',{'model':loaded['name'],'keep_alive':0},timeout=30)
        for _ in range(50):
            if not api(a.base,'/api/ps')['models']: return
            time.sleep(.2)
        raise RuntimeError('Could not establish an empty model queue')
    try:
        unload()
        # Bound model weights to 75% of physical memory before attempting an oversized candidate.
        if installed[model]['size'] > metadata['memory_bytes']*.75:
            metadata.update(status='hardware_blocked',reason='Model file alone exceeds 75% of unified memory; no room budgeted for macOS, runtime and context.');save();return
        if shutil.disk_usage(root).free<2*1024**3: raise RuntimeError('Less than 2 GiB free; stop before further memory pressure')
        cold_started=time.monotonic(); cold=api(a.base,'/api/chat',{'model':model,'messages':[{'role':'user','content':'Reply only READY.'}],'stream':False,'options':manifest['profile'],'keep_alive':'10m'},timeout=180)
        metadata['cold_start_seconds']=time.monotonic()-cold_started;metadata['cold_response']=cold;save()
        loaded=api(a.base,'/api/ps')['models']
        metadata['preflight_loaded_samples']=[loaded]
        # The runner can disappear briefly from /ps while the runtime replaces a context.
        # Wait only for an empty report; never overlook an unexpected loaded model.
        for _ in range(10):
            if loaded: break
            time.sleep(.2); loaded=api(a.base,'/api/ps')['models'];metadata['preflight_loaded_samples'].append(loaded)
        save()
        if len(loaded)!=1 or loaded[0]['digest']!=installed[model]['digest']: raise RuntimeError('Wrong model or multiple models loaded after preflight; see preflight_loaded_samples')
        if not cold.get('done') or not cold.get('message',{}).get('content'): raise RuntimeError('Model health preflight returned no completed answer')
        metadata['swap_after_load_bytes']=swap()
        metadata['swap_guard_basis']='Growth beyond 2 GiB after cold model load; initial loading swap retained separately.'
        save()
        failures=0; infrastructure_streak=0
        for repetition in range(1,manifest['repetitions']+1):
            # Stable rotated order reduces one model benefiting solely from original fixture ordering.
            cases=manifest['cases'];offset=(repetition-1)*17%len(cases); ordered=cases[offset:]+cases[:offset]
            for case in ordered:
                start=time.monotonic();record={'id':case['id'],'model':model,'repeat':repetition,'category':case['category'],'scope':case['scope'],'kind':case['kind'],'prompt':case['prompt'],'timestamp':now(),'manifest_sha256':fingerprint}
                if case.get('direct'):
                    record.update(status='deterministic',actual=case['direct'],latency_seconds=0)
                else:
                    if shutil.disk_usage(root).free<1024**3: raise RuntimeError('Disk below 1 GiB reserve; hardware run stopped')
                    before=swap(); ps=api(a.base,'/api/ps')['models']
                    if any(m['digest']!=installed[model]['digest'] for m in ps): raise RuntimeError('Another client changed the loaded model; run stopped to preserve serial isolation')
                    maximum={'runtime_size_bytes':0,'runtime_vram_bytes':0,'rss_bytes':0,'multiple_loaded':False};stop=threading.Event()
                    def sample():
                        while not stop.is_set():
                            try:
                                active=api(a.base,'/api/ps',timeout=2)['models']
                                maximum['multiple_loaded'] |= len(active)>1 or any(m['digest']!=installed[model]['digest'] for m in active)
                                maximum['runtime_size_bytes']=max(maximum['runtime_size_bytes'],sum(m.get('size',0) for m in active))
                                maximum['runtime_vram_bytes']=max(maximum['runtime_vram_bytes'],sum(m.get('size_vram',0) for m in active))
                                processes=subprocess.check_output(['ps','-axo','rss=,comm='],text=True)
                                rss=sum(int(line.strip().split(None,1)[0])*1024 for line in processes.splitlines() if re.search(r'/(ollama|llama-server)(?:\s|$)',line))
                                maximum['rss_bytes']=max(maximum['rss_bytes'],rss)
                            except Exception: pass
                            stop.wait(1)
                    sampler=threading.Thread(target=sample,daemon=True);sampler.start()
                    try:
                        result=api(a.base,'/api/chat',payload(case,manifest,model),timeout=manifest['timeout_seconds'])
                        errors,actual=grade(case,result,manifest['snapshot'])
                        record.update(status='fail' if errors else 'pass',errors=errors,actual=actual,response=result)
                        if errors: failures+=1
                        infrastructure_streak=0
                    except urllib.error.HTTPError as error:
                        record.update(status='infrastructure',error='HTTP '+str(error.code)+': '+error.read(1500).decode(errors='replace'));infrastructure_streak+=1
                    except (TimeoutError,ConnectionError,urllib.error.URLError) as error:
                        record.update(status='infrastructure',error=str(error));infrastructure_streak+=1
                    finally:
                        stop.set();sampler.join(timeout=3)
                    record.update(latency_seconds=time.monotonic()-start,memory=maximum,swap_before_bytes=before,swap_after_bytes=swap())
                    if maximum['multiple_loaded']: record.update(status='infrastructure',error='Concurrent model load detected')
                with log.open('a') as f: f.write(json.dumps(record)+'\n');f.flush();os.fsync(f.fileno())
                print(f'{now()} {model} repeat {repetition} {case["id"]}: {record["status"]} {record.get("latency_seconds",0):.1f}s',flush=True)
                if record.get('memory',{}).get('multiple_loaded'): raise RuntimeError('Concurrent model load detected; no quality score for contaminated case')
                if infrastructure_streak>=3: raise RuntimeError('Three consecutive infrastructure failures; remaining cases not run')
                current_swap=swap()
                if current_swap is not None and metadata['swap_after_load_bytes'] is not None and current_swap-metadata['swap_after_load_bytes']>2*1024**3: raise RuntimeError('Swap grew by over 2 GiB after model load; hardware-pressure stop')
        metadata.update(status='completed',finished=now(),failed_cases=failures)
    except Exception as error:
        metadata.update(status='incomplete',finished=now(),reason=str(error));print('STOP:',error,flush=True)
    finally:
        # Unload only this test model; do not evict a new model another client requested.
        try: api(a.base,'/api/generate',{'model':model,'keep_alive':0},timeout=30)
        except Exception as error: metadata['unload_error']=str(error)
        try: metadata['models_loaded_at_end']=api(a.base,'/api/ps')['models']
        except Exception: pass
        metadata['swap_end_bytes']=swap();save()

if __name__=='__main__': main()
