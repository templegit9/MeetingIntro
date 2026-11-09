"""Run a reviewed local Python script in workstation WSL over configured SSH."""
import base64, pathlib, subprocess, sys
source=pathlib.Path(sys.argv[1]).read_bytes()
python="import base64;exec(compile(base64.b64decode('"+base64.b64encode(source).decode()+"'),'<remote>','exec'))"
ps="& wsl -d Ubuntu-24.04 -- python3 -c \""+python+"\""
command='powershell -NoProfile -EncodedCommand '+base64.b64encode(ps.encode('utf-16le')).decode()
raise SystemExit(subprocess.call(['ssh','-o','BatchMode=yes','oluyi@100.126.58.91',command]))
