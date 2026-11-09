import pathlib,json,hashlib,shutil,sys,ast,datetime
repo=pathlib.Path(__file__).resolve().parents[2];out=repo/'docs/evals/margin-vision/comparison-20260913';out.mkdir(exist_ok=False)
sys.path.insert(0,str(repo/'scripts/margin-model-eval-v3'));from policy import upgrade
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
pre=json.load(open('/private/tmp/margin-comparison-preflight.json'));assert pre['training_image_hashes'],'No training assets audited'
for name in ['worker.py','supervisor.py']:shutil.copyfile(pathlib.Path(__file__).with_name(name),out/name)
shutil.copyfile(repo/'scripts/margin-model-eval-v3/grading.py',out/'grading.py');shutil.copyfile(repo/'scripts/margin-vision-eval/eval.py',out/'vision_grading.py')
old=repo/'docs/evals/margin-lora/20260912T045552Z-final-comparison/manifest.json';lang=json.loads(old.read_text());lang['cases']=[upgrade(c) for c in lang['cases']]
ns={};exec((repo/'scripts/margin-model-eval/fixtures.py').read_text(),ns);lang['clock']=ns['CLOCK'];(out/'language.json').write_text(json.dumps(lang,indent=2))
(out/'vision').mkdir();shutil.copyfile(repo/'docs/evals/margin-vision/suite.json',out/'vision/suite.json');shutil.copytree(repo/'docs/evals/margin-vision/assets',out/'vision/assets')
vision=json.loads((out/'vision/suite.json').read_text())
for c in vision['cases']:
 for p,h in c['asset_sha256'].items():
  assert sha(out/'vision'/p)==h
  assert h not in pre['training_image_hashes'],'Training image overlap'
mod=ast.parse((repo/'scripts/margin-vision-eval/run_full.py').read_text());system=next(ast.literal_eval(n.value) for n in mod.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='system' for t in n.targets))
m=dict(created_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),candidates=['unadapted','epoch-1','epoch-2','epoch-3'],requests_per_candidate=sum(not c.get('direct') for c in lang['cases'])*3+len(vision['cases'])*3,language_requests=sum(not c.get('direct') for c in lang['cases'])*3,image_requests=len(vision['cases'])*3,repeats=3,source={'repo':'empero-ai/Qwen3.8-4B-Distill','revision':'c83cb7aa2999d2f35c43e9ae0634a30eb8985a1e'},hf_home='/mnt/c/Users/oluyi/Documents/Projects/Margin-Empero-LoRA/cache/huggingface',training_root='/mnt/c/Users/oluyi/Documents/Projects/Margin-Vision-Pilot/mixed-pilot-20260913',adapter_hashes=pre['adapter_hashes'],vision_system=system,language_manifest_sha256=sha(old),training_assets_checked=len(pre['training_image_hashes']),generation={'max_new_tokens':2048,'max_time':120,'do_sample':False,'enable_thinking':False},limitations=['Image fixtures excluded from training by exact asset hash; previously used for source screening, not a blind holdout.','Language checks use the full frozen 108-case suite, including deterministic cases excluded from model scores.','Transformers BF16 GPU comparison; no Mac memory or quantized runtime qualification.','Learning schema is prompted; Transformers does not reproduce Ollama constrained decoding.','Synthetic image screening passes require human rubric review.'])
m['files']={str(p.relative_to(out)):sha(p) for p in out.rglob('*') if p.is_file()}
(out/'manifest.json').write_text(json.dumps(m,indent=2));(out/'supervisor.json').write_text(json.dumps({'timestamp':m['created_at'],'stage':'prepared; uploading to workstation'}));print(out);print(m['requests_per_candidate'])
