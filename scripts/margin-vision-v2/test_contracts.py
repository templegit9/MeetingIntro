import unittest,sys,pathlib,json
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[2]/'docs/evals/margin-vision/separated-20260913'))
from contracts import shape,reader_grade,planner_grade
class Contracts(unittest.TestCase):
 def test_table_types(self):
  row=shape([['Month',1,2]])['items']['prefixItems'];self.assertEqual([x['type'] for x in row],['string','number','number'])
 def test_no_values_leak(self):self.assertNotIn('Lantern',json.dumps(shape([{'title':'Lantern','all_day':True}])))
 def test_reader_wrong_amount(self):self.assertTrue(reader_grade({'id':'X','facts':{'total':19.44}},'{"facts":{"total":1944},"uncertainties":[]}')[0])
 def test_reader_noimage(self):self.assertTrue(reader_grade({'id':'X','facts':{},'must_be_empty':True,'uncertainty_required':True},'{"facts":{"subject":"Diagram"},"uncertainties":[]}')[0])
 def test_calendar_folder_rejected(self):
  snapshot={'tools':[{'function':{'name':'create_events','parameters':{'type':'object','properties':{'events':{'type':'array','items':{'type':'object','properties':{}}}}}}}]}
  response={'message':{'content':'','tool_calls':[{'function':{'name':'create_events','arguments':{'events':[],'destination':'Downloads'}}}]}}
  self.assertIn('Unknown native argument destination',planner_grade({'tool':'create_events'},response,snapshot))
 def test_clarification_cannot_call(self):
  self.assertIn('Unexpected tool call',planner_grade({'answer_patterns':['date']},{'message':{'content':'which date?','tool_calls':[{'function':{'name':'create_events'}}]}},{'tools':[]}))
if __name__=='__main__':unittest.main()
