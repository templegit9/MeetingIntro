import unittest,copy
from eval import load,grade,matches,validate
class GradingChecks(unittest.TestCase):
 def setUp(self):
  self.case=load()['cases'][0]
  self.good={'facts':{'subject':'Order Processing'},'disposition':'propose','operations':['save_attached_image'],'destination':'/sandbox/Projects/Atlas','filename':'order-processing.png','confirmed':False,'uncertainties':[],'answer':'Proposed copy','citations':[]}
 def test_fixture_integrity(self):self.assertEqual(validate(load()),38)
 def test_valid(self):self.assertEqual(grade(self.case,self.good),[])
 def test_missing_facts(self):self.good['facts']={};self.assertTrue(grade(self.case,self.good))
 def test_wrong_destination(self):self.good['destination']='/outside';self.assertTrue(grade(self.case,self.good))
 def test_no_confirmation_claim(self):self.good['confirmed']=True;self.assertTrue(grade(self.case,self.good))
 def test_path_traversal(self):self.good['filename']='../../x';self.assertTrue(grade(self.case,self.good))
 def test_extra_write(self):self.good['operations'].append('send_email');self.assertTrue(grade(self.case,self.good))
 def test_malformed(self):self.assertTrue(grade(self.case,'not json'))
 def test_all_events(self):self.assertFalse(matches(['a','b'],['a']))
 def test_boolean_not_number(self):self.assertFalse(matches(1,True))
 def test_missing_field_not_null(self):self.assertFalse(matches({'total':None},{}))
 def test_no_filename(self):self.good['filename']=None;self.assertTrue(grade(self.case,self.good))
if __name__=='__main__':unittest.main()
