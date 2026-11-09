"""Read-only training dashboard; serve on loopback and access remotely through SSH."""
import pathlib,json,argparse,http.server,datetime,collections
p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--port',type=int,default=8766);a=p.parse_args();ROOT=pathlib.Path(a.root)
def readjson(path,default):
 try:return json.loads(path.read_text())
 except (ValueError,OSError):return default
def tail(path,n=12000):
 try:
  with path.open('rb') as f:f.seek(0,2);size=f.tell();f.seek(max(0,size-n));return f.read().decode(errors='replace')
 except OSError:return ''
def rows(path,n=400):
 out=[]
 for l in tail(path,500000).splitlines():
  try:out.append(json.loads(l))
  except ValueError:pass
 return out[-n:]
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  if self.path=='/' or self.path.startswith('/?'):
   data=(ROOT/'scripts/dashboard.html').read_bytes();ctype='text/html; charset=utf-8'
  elif self.path=='/api/status':
   s=readjson(ROOT/'status.json',{});mode=s.get('mode','smoke')
   payload={'fetched_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'state':s,'metrics':rows(ROOT/'logs/metrics.jsonl'),'gpu':rows(ROOT/'logs/gpu.jsonl',120),'data':readjson(ROOT/'data/manifest.json',{}),'revision':readjson(ROOT/'artifacts/base-revision.json',{}),'log':tail(ROOT/f'logs/{mode}.log'),'checkpoints':[str(x.relative_to(ROOT)) for x in (ROOT/'artifacts').glob('*/checkpoint-*') if x.is_dir()],'project':r'C:\Users\oluyi\Documents\Projects\Margin-Empero-LoRA'}
   data=json.dumps(payload).encode();ctype='application/json'
  else:self.send_error(404);return
  self.send_response(200);self.send_header('Content-Type',ctype);self.send_header('Cache-Control','no-store');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def log_message(self,*args):pass
print('Dashboard listening on http://127.0.0.1:'+str(a.port),flush=True)
http.server.ThreadingHTTPServer(('127.0.0.1',a.port),Handler).serve_forever()
