from pathlib import Path
import re,html,datetime,json
R=Path(__file__).resolve().parents[2];D=R/'docs/evals/margin-vision'
def inline(s):
 s=html.escape(s)
 s=re.sub(r'\[([^\]]+)\]\(([^)]+)\)',lambda m:'<a href="'+(m[2].replace('evals/margin-vision/','') if not m[2].startswith('http') else m[2])+'">'+m[1]+'</a>',s)
 return s
def render(source,target):
 out=[];table=False
 for line in source.read_text().splitlines():
  if line.startswith('|'):
   if re.fullmatch(r'[| :\-]+',line):continue
   if not table:out.append('<table>');table=True;tag='th'
   else:tag='td'
   out.append('<tr>'+''.join(f'<{tag}>{inline(c.strip())}</{tag}>' for c in line.strip('|').split('|'))+'</tr>');continue
  if table:out.append('</table>');table=False
  if line.startswith('#'):
   n=len(line)-len(line.lstrip('#'));out.append(f'<h{n}>'+inline(line[n:].strip())+f'</h{n}>')
  elif line:out.append('<p>'+inline(line)+'</p>')
 target.write_text('<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Margin vision model review</title><style>body{max-width:1100px;margin:35px auto;padding:24px;background:#f7f5ed;color:#263b2c;font:16px/1.6 system-ui}h1,h2{font-family:Georgia}a{color:#236843}table{border-collapse:collapse;width:100%}td,th{padding:14px;border-bottom:1px solid #b8c5b5;text-align:left;vertical-align:top}th{background:#e2e9db}@media(max-width:700px){table{display:block;overflow-x:auto}}</style><p><a href="index.html">Image eval catalogue</a> · Updated '+datetime.datetime.now(datetime.timezone.utc).isoformat()+'</p>'+''.join(out)+'</html>')

render(R/'docs/margin-vision-model-review.md',D/'model-review.html')
render(R/'docs/margin-vision-eval-plan.md',D/'plan.html')
