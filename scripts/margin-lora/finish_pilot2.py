"""Watch the authorized remote pilot, verify export, then evaluate serially."""
import pathlib,subprocess,time,json,hashlib,sys,urllib.request,datetime
repo=pathlib.Path(__file__).resolve().parents[2];root=repo/'docs/evals/margin-lora/pilot2-preparation';remote='/mnt/c/Users/oluyi/Documents/Projects/Margin-Empero-LoRA-Pilot2';host='oluyi@100.126.58.91'
def ssh(args):return subprocess.check_output(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=10',host,args],text=True,timeout=40)
def state(stage,**kw):
 d=dict(stage=stage,timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(),**kw);(root/'pipeline-status.json').write_text(json.dumps(d,indent=2));print(json.dumps(d),flush=True)
state('waiting_for_training_and_export')
for _ in range(720):
 try:s=json.loads(ssh('wsl -d Ubuntu-24.04 -- cat '+remote+'/status.json'))
 except (subprocess.SubprocessError,ValueError):time.sleep(30);continue
 if s.get('stage')=='awaiting_gpu_approval':state('awaiting_gpu_approval');raise SystemExit('User approval required before further workstation GPU use')
 if s.get('stage')=='failed':state('blocked',remote_status=s);raise SystemExit('Remote job failed; inspect before retry')
 if s.get('stage')=='exports_ready':break
 time.sleep(30)
else:raise SystemExit('Export not ready within six hours; no evaluation started')
export=json.loads(ssh('wsl -d Ubuntu-24.04 -- cat '+remote+'/artifacts/pilot-exports/manifest.json'))
(root/'export-manifest.json').write_text(json.dumps(export,indent=2))
# State includes exact quantized path and checksum from the converter.
e=s['exports'][0];assert e['name']=='pilot-adapted';f=pathlib.Path('/private/tmp/margin-pilot2-final.gguf');assert not f.exists(),'Refuse to overwrite an existing transfer'
state('transferring',sha256=e['sha256'])
# Windows SCP accesses D: directly; artifacts directory is a WSL symlink.
subprocess.run(['scp',host+':D:/llm/Margin-Empero-LoRA-Pilot2-artifacts/pilot-exports/pilot-adapted-Q4_K_M.gguf',str(f)],check=True)
assert f.stat().st_size==e['bytes'];assert hashlib.file_digest(f.open('rb'),'sha256').hexdigest()==e['sha256']
mod=pathlib.Path('/private/tmp/margin-pilot2.Modelfile');mod.write_text('FROM '+str(f)+'\nPARAMETER num_ctx 8192\nPARAMETER temperature 0\n')
with (root/'import.log').open('w') as log:subprocess.run(['/opt/homebrew/bin/ollama','create','margin-lora-pilot2:final','-f',str(mod)],stdout=log,stderr=subprocess.STDOUT,check=True)
subprocess.run([sys.executable,str(repo/'scripts/margin-lora/check_ollama_export.py'),'--model','margin-lora-pilot2:final','--snapshot','/private/tmp/margin-model-snapshot.json','--output',str(root/'compatibility.json')],check=True)
f.unlink()
for suite in ['regression-eval','holdout-eval']:
 state('evaluating',suite=suite)
 subprocess.run([sys.executable,str(repo/'scripts/margin-lora/run_comparison.py'),str(root/suite)],check=True)
state('evaluations_complete_pending_review')
