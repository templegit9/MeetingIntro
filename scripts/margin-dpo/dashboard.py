import pathlib,json,argparse
from http.server import HTTPServer,BaseHTTPRequestHandler
p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--port',type=int,default=8769);a=p.parse_args();root=pathlib.Path(a.root)
page='''<!doctype html><html><meta charset="utf-8"><title>Margin DPO pilot</title><style>body{max-width:900px;margin:40px auto;padding:24px;background:#f7f5ed;color:#263b2c;font:17px/1.6 system-ui}h1{font-family:Georgia}pre{white-space:pre-wrap;background:#e8ecdf;padding:20px}</style><h1>Margin / DPO pilot</h1><p>RTX 5070 Ti · preference training · no app promotion</p><p>Four-step resource preflight first. Full pilot starts only after it passes. Training loss and preference reward are not task accuracy.</p><pre id="status">Loading…</pre><script>async function refresh(){try{let r=await fetch('/api/status');let d=await r.json();document.getElementById('status').textContent=JSON.stringify(d,null,2)}catch(e){document.getElementById('status').textContent='Connection unavailable — status unknown'}}refresh();setInterval(refresh,5000)</script></html>'''
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  if self.path=='/api/status':data=(root/'status.json').read_bytes() if (root/'status.json').exists() else b'{"stage":"waiting"}';mime='application/json'
  elif self.path=='/':data=page.encode();mime='text/html; charset=utf-8'
  else:self.send_error(404);return
  self.send_response(200);self.send_header('Content-Type',mime);self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(data)
HTTPServer(('127.0.0.1',a.port),Handler).serve_forever()
