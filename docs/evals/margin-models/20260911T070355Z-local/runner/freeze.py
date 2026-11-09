import argparse, hashlib, json, pathlib, datetime, shutil
from fixtures import expand, MODELS, PROFILE
p=argparse.ArgumentParser();p.add_argument('snapshot');p.add_argument('output');p.add_argument('--binary',required=True);p.add_argument('--models',nargs='+',choices=MODELS);a=p.parse_args()
out=pathlib.Path(a.output);out.mkdir(parents=True,exist_ok=False)
snapshot=json.loads(pathlib.Path(a.snapshot).read_text())
manifest={'version':1,'frozen_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'models':MODELS,'repetitions':3,'clock':'2026-09-10T12:00:00-07:00','profile':PROFILE,'timeout_seconds':120,'snapshot':snapshot,'cases':expand(snapshot),'binary_sha256':hashlib.sha256(pathlib.Path(a.binary).read_bytes()).hexdigest(),'code_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in pathlib.Path(__file__).parent.glob('*.py')},'scope':'Exact exported production prompts and tool schemas. No provider writes. Research uses synthetic fixed excerpts; reasoning is a capability probe; recovery supplies simulated feedback. Deterministic dispatch excluded from model scores. Regex checks are bounded acceptance assertions, not complete semantic judgments.'}
if a.models: manifest['models']=a.models
raw=json.dumps(manifest,indent=2,sort_keys=True).encode();(out/'manifest.json').write_bytes(raw);(out/'manifest.sha256').write_text(hashlib.sha256(raw).hexdigest()+'\n')
print(len(manifest['cases']),'cases; frozen at',out)
