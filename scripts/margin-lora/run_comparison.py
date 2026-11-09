"""Run frozen comparison arms serially and refresh the HTML evidence while running."""
import pathlib,subprocess,sys,json,time,argparse,importlib.util,urllib.request
p=argparse.ArgumentParser();p.add_argument('directory');a=p.parse_args();root=pathlib.Path(a.directory)
runner=pathlib.Path(__file__).parent.parent/'margin-model-eval';spec=importlib.util.spec_from_file_location('report',runner/'report.py');report=importlib.util.module_from_spec(spec);spec.loader.exec_module(report)
from compare_report import build as compare_build
manifest=json.loads((root/'manifest.json').read_text())
for model in manifest['models']:
 key=model.replace(':','-').replace('/','-')
 with (root/(key+'-console.log')).open('w') as log:
  process=subprocess.Popen([sys.executable,str(runner/'run.py'),str(root),'--model',model],stdout=log,stderr=subprocess.STDOUT)
  while process.poll() is None:
   report.build(root);compare_build(root);time.sleep(10)
 report.build(root);compare_build(root)
 meta=json.loads((root/(key+'-run.json')).read_text())
 print(model,meta.get('status'),meta.get('failed_cases'),flush=True)
 if process.returncode or meta.get('status')!='completed':raise SystemExit('Stopped on incomplete candidate: '+model)
 with urllib.request.urlopen('http://127.0.0.1:11434/api/ps') as r:assert not json.load(r)['models'],'Model failed to unload between arms'
print('Comparison finished. Inspect quality gates before any promotion.',flush=True)
