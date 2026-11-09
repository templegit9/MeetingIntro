import unittest,copy
from audit import decode,facts_check
class AuditTests(unittest.TestCase):
 def test_fence(self):self.assertEqual(decode('```json\n{"a":1}\n```'),({'a':1},True))
 def test_no_substring_salvage(self):self.assertIsNone(decode('Done {"a":1}')[0])
 def test_equivalent_edges(self):
  c={'id':'IMG-005','expected':{'facts':{'edges':['A->B']}}}
  self.assertEqual(facts_check(c,{'facts':{'edges':['A → B']}}),'equivalent representation')
 def test_reversed_edge_not_equal(self):
  c={'id':'IMG-005','expected':{'facts':{'edges':['A->B']}}}
  self.assertEqual(facts_check(c,{'facts':{'edges':['B->A']}}),'mismatch or missing requested field')
 def test_real_amount_error_not_coerced(self):
  c={'id':'IMG-006','expected':{'facts':{'total':13.5}}}
  self.assertEqual(facts_check(c,{'facts':{'total':135}}),'mismatch or missing requested field')
 def test_no_invented_facts_for_empty_target(self):self.assertEqual(facts_check({'id':'IMG-025','expected':{'facts':{}}},None),'not annotated')
 def test_does_not_modify_raw_object(self):
  c={'id':'IMG-005','expected':{'facts':{'edges':['A->B']}}};obj={'facts':{'edges':['A → B']},'confirmed':True};before=copy.deepcopy(obj);facts_check(c,obj);self.assertEqual(obj,before)
if __name__=='__main__':unittest.main()
