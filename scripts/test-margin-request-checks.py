import pathlib,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
s=(root/'MeetingIntro/Margin/BatchCalendarTools.swift').read_text()
text=s[:s.index('struct CreateEventsTool')]+s[s.index('enum MarginRequestChecks'):]+(root/'scripts/margin-request-checks.swift').read_text()
with tempfile.TemporaryDirectory(prefix='margin-guards-') as tmp:
 p=pathlib.Path(tmp)/'checks.swift';p.write_text(text);subprocess.run(['swift',str(p)],check=True)
