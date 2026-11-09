"""Freeze the original regression suite unchanged for serial LoRA/control comparison."""
import pathlib,json,hashlib,datetime,argparse
p=argparse.ArgumentParser();p.add_argument('--baseline',required=True);p.add_argument('--output',required=True);a=p.parse_args()
base=pathlib.Path(a.baseline);out=pathlib.Path(a.output);runner=pathlib.Path(__file__).parent.parent/'margin-model-eval'
d=json.loads((base/'manifest.json').read_text());assert d['code_sha256']['grading.py']==hashlib.sha256((runner/'grading.py').read_bytes()).hexdigest(),'Grader changed; review before comparison'
d['source_baseline_manifest_sha256']=hashlib.sha256((base/'manifest.json').read_bytes()).hexdigest();d['frozen_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();d['models']=['margin-lora-base-control:preflight','margin-lora-pilot:final'];d['code_sha256']={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in runner.glob('*.py')};d['comparison_note']='Original frozen cases, prompts, schema, clock and profile; fresh unadapted conversion control versus final pilot checkpoint. No prompt edits. This is regression evaluation, not an independent holdout or app deployment.'
out.mkdir(parents=True,exist_ok=False);raw=json.dumps(d,indent=2,sort_keys=True).encode();(out/'manifest.json').write_bytes(raw);(out/'manifest.sha256').write_text(hashlib.sha256(raw).hexdigest()+'\n');print(out)
