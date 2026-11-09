"""Accounting checks for the developer report; no browser or provider requests."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('report',Path(__file__).with_name('render-margin-eval.py'))
report=importlib.util.module_from_spec(spec); spec.loader.exec_module(report)

class ReportTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.root=Path(self.temp.name)
        self.run=self.root/'run'; self.run.mkdir()
    def tearDown(self): self.temp.cleanup()
    def write(self,name,data):
        (self.run/name).write_text(json.dumps(data) if not isinstance(data,str) else data)
    def load(self): return report.load_run(self.run,self.root)
    def test_failed_guard_cannot_be_green(self):
        self.write('results.json',{'complete':True,'date':'2026-09-11T01:00:00Z','cases':[]})
        self.write('run.log','  ✗ filterless trash refuses\n  0/1 guards held\n')
        result=self.load(); self.assertEqual(result['status'],'Completed with failures'); self.assertEqual(result['counts']['fail'],1)
    def test_infrastructure_is_not_a_scored_failure(self):
        self.write('results.json',{'complete':False,'cases':[{'id':'routing-1','expected':['web_research'],'status':'infrastructure','prompt':'search'}], 'planned_cases':[{'id':'routing-1'},{'id':'routing-2','prompt':'files','expected':['find_files']}]})
        result=self.load(); self.assertEqual(result['counts']['fail'],0); self.assertEqual(result['counts']['infrastructure'],1); self.assertEqual(result['counts']['not_run'],1)
    def test_review_preserves_raw_failure_and_excludes_invalid_test(self):
        self.write('results.json',{'complete':True,'cases':[]})
        self.write('run.log','  ✗ paused learning leaves preferences unchanged\n  0/1 roadmap guards held\n')
        self.write('run-review.json',{'checks':{'paused learning leaves preferences unchanged':{'status':'invalid_test','reason':'wrong baseline'}}})
        result=self.load(); self.assertEqual(result['rows'][0]['raw_status'],'fail'); self.assertEqual(result['counts']['fail'],0); self.assertEqual(result['counts']['invalid_test'],1)
    def test_run_start_comes_from_runner_not_last_checkpoint(self):
        self.write('results.json',{'date':'2026-09-11T02:00:00Z','cases':[]})
        self.write('run-info.json',{'started_at':'2026-09-11T01:00:00Z','finished_at':'2026-09-11T02:01:00Z'})
        self.assertEqual(self.load()['started_at'],'2026-09-11T01:00:00Z')
    def test_live_learning_not_counted_as_deterministic(self):
        self.write('run.log','  ✓ learned soul survives reload\n  ✓ live local model forms working-hours memory\n  2/2 roadmap guards held\n')
        result=self.load(); self.assertEqual([r['kind'] for r in result['rows']],['Deterministic check','Live learning'])
        self.assertEqual(result['counts']['pass'],2)
    def test_tool_coverage_uses_expected_routes_not_wrong_model_calls(self):
        self.write('results.json',{'registered_tools':['find_files','trash_files'],'cases':[{'expected':['find_files'],'actual':'trash_files','passed':False}]})
        result=self.load(); self.assertEqual(result['tool_coverage'],1); self.assertEqual(result['missing_tools'],['trash_files'])
    def test_unfinished_runner_does_not_disappear(self):
        self.write('run-info.json',{'started_at':'2026-09-11T01:00:00Z'})
        self.assertEqual(self.load()['status'],'Incomplete')

if __name__=='__main__': unittest.main()
