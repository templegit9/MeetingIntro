import unittest
from render_dashboard import tool_check,render
class Checks(unittest.TestCase):
 def row(self,raw):return {'raw':raw,'target':{'tool_calls':[{'function':{'name':'create_events','arguments':{'events':[{'title':'Test','all_day':True}]}}}]}}
 def test_native_qwen_call(self):self.assertEqual(tool_check(self.row('<tool_call><function=create_events><parameter=events>[{"title":"Test","all_day":true}]</parameter></function></tool_call>')),'Exact match')
 def test_wrong_count_fails(self):self.assertEqual(tool_check(self.row('<tool_call><function=create_events><parameter=events>[]</parameter></function></tool_call>')),'Mismatch')
 def test_prose_needs_review(self):self.assertEqual(tool_check({'raw':'Done','target':{'content':'Not done'}}),'Review pending')
 def test_truncation_not_pass(self):self.assertEqual(tool_check({'truncated':True}),'Truncated')
 def test_no_worker_is_visible(self):self.assertIn('Worker not running',render({}))
 def test_connection_error_retains_detail(self):
  result=render({},error='offline');self.assertIn('Connection unavailable',result);self.assertIn('Dataset by category',result);self.assertIn('Not run',result)
if __name__=='__main__':unittest.main()
