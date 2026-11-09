from strict_grading import schema_errors,grade as strict_grade
import copy,re
def grade(case,response,snapshot):
 c=copy.deepcopy(case)
 if c['id']=='learn-3':
  c['keys']=list(set(c['keys']+['format']))
 errors,actual=strict_grade(c,response,snapshot)
 if c['id']=='learn-3' and not any(re.search(r'(?i)(detailed|in.depth|thorough|longer)',str(e.get('value',''))) and not re.search(r'(?i)(dislike|avoid|do not|does not|less detail)',str(e.get('value',''))) for e in actual.get('entries',[]) if isinstance(e,dict)):
  errors.append('Detailed-explanation preference meaning missing')
 return errors,actual
