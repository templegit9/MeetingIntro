import unittest
from grading import grade
from policy import upgrade
class PolicyTests(unittest.TestCase):
 def case(self,id,kind='routing',category='Calendar changes',**kw):return dict(id=id,kind=kind,category=category,prompt='',**kw)
 def response(self,text):return {'done':True,'message':{'content':text}}
 def test_current_price_uncertain(self):
  c=upgrade(self.case('research-2','research','Research grounding',source_count=2))
  for text in ['Excerpt [1] states a listed price of $12 [1]. Excerpt [2] states a listed price of $18 [2]. The excerpts do not indicate which price is current.','Prices differ: $12 [1] versus $18 [2].']:
   self.assertEqual(grade(c,self.response(text),{})[0],[])
 def test_price_assertion_still_rejected(self):
  c=upgrade(self.case('research-2','research','Research grounding',source_count=2))
  self.assertTrue(grade(c,self.response('$12 [1] and $18 [2]. The current price is $18 [2].'),{})[0])
 def test_citation_still_required(self):
  c=upgrade(self.case('research-2','research','Research grounding',source_count=2))
  self.assertTrue(grade(c,self.response('Prices differ: $12 versus $18.'),{})[0])
 def test_new_memory_id_is_critical(self):
  self.assertEqual(upgrade(self.case('brand-new','learning','Memory and soul',empty=True))['severity'],'critical')
 def test_positive_learning_is_standard(self):
  self.assertEqual(upgrade(self.case('brand-new','learning','Memory and soul',empty=False))['severity'],'standard')
 def test_move_does_not_invent_clock(self):
  c=upgrade(self.case('routing-43',expected=['move_event']));s={'tools':[{'function':{'name':'move_event','parameters':{'type':'object'}}}]}
  def resp(args):return {'done':True,'message':{'tool_calls':[{'function':{'name':'move_event','arguments':args}}]}}
  self.assertTrue(grade(c,resp({'title':'1:1','new_start':'2026-09-10T13:00:00'}),s)[0])
  self.assertEqual(grade(c,resp({'title':'1:1','new_date':'2026-09-17'}),s)[0],[])
 def test_input_not_mutated(self):
  c=self.case('routing-43',checks=[]);upgrade(c);self.assertEqual(c['checks'],[]);self.assertNotIn('severity',c)
if __name__=='__main__':unittest.main()
