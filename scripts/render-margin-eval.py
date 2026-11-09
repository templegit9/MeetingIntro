#!/usr/bin/env python3
"""Categorized, timestamped developer evidence. Original run artifacts stay immutable."""
import argparse
import datetime as dt
import json
import re
from pathlib import Path

CATEGORIES = ['File reads', 'File changes', 'Calendar reads', 'Calendar changes', 'Tasks',
              'Jobs and schedules', 'Recordings and notes', 'Web research', 'Capabilities',
              'Safety boundaries', 'Memory and soul', 'History and continuity', 'Notebook inactivity']
TOOLS = {
    'File reads': ['find_files', 'find_files_by_content', 'folder_summary', 'where_is'],
    'File changes': ['move_files', 'trash_files', 'create_folder', 'rename_files'],
    'Calendar reads': ['whats_on_today', 'find_time', 'day_briefing'],
    'Calendar changes': ['create_event', 'create_events', 'move_event', 'cancel_event', 'rsvp'],
    'Tasks': ['create_task', 'list_tasks', 'complete_task'],
    'Jobs and schedules': ['list_jobs', 'pause_job', 'resume_job', 'watch_folder', 'schedule_organize'],
    'Recordings and notes': ['list_recordings', 'search_transcripts', 'generate_notes'],
    'Web research': ['web_research'], 'Capabilities': ['list_capabilities']}

def category(row):
    if row.get('category'): return row['category']
    if '(declined)' in row.get('expected', []): return 'Safety boundaries'
    for name, tools in TOOLS.items():
        if any(t in tools for t in row.get('expected', [])): return name
    return 'Safety boundaries'

def check_category(label, group):
    value = label.lower()
    if any(x in value for x in ['idle notebook', 'never-rest']): return 'Notebook inactivity'
    if any(x in value for x in ['soul', 'learning', 'learned', 'preference', 'memory', 'forget', 'credential request', 'permission escalation']): return 'Memory and soul'
    if any(x in value for x in ['history', 'receipts', 'pages', 'archive']): return 'History and continuity'
    if any(x in value for x in ['brave', 'search results', 'search response', 'web query', 'search key', 'quota errors', 'search limit']): return 'Web research'
    if any(x in value for x in ['job', 'restart', 'resume', 'reconcil', 'in-flight', 'journal', 'pause finishes', 'following writes', 'completed steps', 'checked noncreation']): return 'Jobs and schedules'
    if any(x in value for x in ['recording', 'transcript']): return 'Recordings and notes'
    if any(x in value for x in ['capability', 'capabilities']): return 'Capabilities'
    if group == 'calendar' or any(x in value for x in ['holiday', 'event', 'batch', 'all-day', 'calendar', 'dated', 'date-only', 'undated']): return 'Calendar changes'
    if group == 'file': return 'File changes' if any(x in value for x in ['rename', 'moving', 'folder name']) else 'Safety boundaries'
    return 'Safety boundaries'

def load_run(directory, root):
    p = directory / 'results.json'
    raw = json.loads(p.read_text()) if p.exists() else {}
    meta_path = directory / 'run-info.json'
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
    log_path = directory / 'run.log'
    log = log_path.read_text() if log_path.exists() else ''
    checks, pending, warnings = [], [], []
    learning_reply = ""
    for line in log.splitlines():
        if line.startswith('Margin eval ·'): break
        match = re.match(r'\s+([✓✗]) (.+)', line)
        if line.startswith('Learning model reply:'):
            learning_reply=line.partition(':')[2].strip()
        elif match:
            pending.append((match[1] == '✓', match[2], learning_reply)); learning_reply=''
        elif learning_reply:
            learning_reply += '\n' + line
        summary = re.search(r'(\d+)/(\d+) (calendar |behavior |roadmap )?guards held', line)
        if summary:
            group = (summary[3] or 'file').strip()
            if len(pending) != int(summary[2]): warnings.append(f'{group}: log detail count differs from its summary')
            for passed, label, reply in pending:
                checks.append(dict(id=f'check-{len(checks)+1}', category=check_category(label, group),
                                   prompt=label, expected=['Assertion holds'], actual='Holds' if passed else 'Does not hold',
                                   status='pass' if passed else 'fail', kind='Live learning' if label.startswith('live local model') else 'Deterministic check',
                                   context=[], model_reply=reply, note=f'{group} check; detailed assertion evidence in run log'))
            pending=[]
    routing=[]
    for i, original in enumerate(raw.get('cases', [])):
        row=dict(original)
        row.update(id=row.get('id', f'routing-{i+1}'), category=category(row),
                   kind='Direct dispatch' if row.get('deterministic') else 'Model routing',
                   status=row.get('status', 'pass' if row.get('passed') else 'fail'))
        if row['status']=='fail':
            row['failure_reason']='Wrong tool selected' if row.get('actual') not in row.get('expected',[]) else 'Selected calendar arguments are missing or invalid'
        routing.append(row)
    present={r['id'] for r in routing}
    for planned in raw.get('planned_cases', []):
        if planned['id'] not in present:
            routing.append(dict(planned, status='not_run', kind='Routing (not run)', actual='Not run', note='No completed result for this planned case'))
    review_path=directory/'run-review.json'
    review=json.loads(review_path.read_text()) if review_path.exists() else {}
    for check in checks:
        assessment=review.get('checks',{}).get(check['prompt'])
        if assessment:
            check['raw_status']=check['status']; check['status']=assessment['status']
            check['note'] += ' Review: ' + assessment['reason']
    rows=routing+checks
    started=meta.get('started_at') or raw.get('started_at') or raw.get('date')
    ended=meta.get('finished_at') or raw.get('finished_at') or None
    counts={s:sum(r['status']==s for r in rows) for s in ['pass','fail','infrastructure','not_run','invalid_test']}
    incomplete=not raw.get('complete', False) or bool(counts['infrastructure'] or counts['not_run'])
    status='Incomplete' if incomplete else ('Completed with failures' if counts['fail'] else ('Completed with invalid tests' if counts['invalid_test'] else 'Passed'))
    if meta.get('exit_code') not in [None, 0] and status=='Passed': status='Incomplete'; warnings.append('Nonzero runner exit without a recorded failing case')
    binary=directory/'binary-sha256.txt'
    registered=raw.get('registered_tools', [])
    represented=set(t for r in routing for t in r.get('expected', []) if t!='(declined)')
    return dict(name=directory.name, started_at=started, finished_at=ended,
                timestamp_label='Started' if meta.get('started_at') or raw.get('started_at') else 'Recorded (legacy)',
                model=raw.get('model','Not recorded yet'), status=status, counts=counts, rows=rows,
                expected_routing=raw.get('expected_cases',0), recorded_routing=len(raw.get('cases',[])),
                registered_tools=registered, missing_tools=sorted(set(registered)-represented),
                tool_coverage=len(set(registered)&represented),
                binary=binary.read_text().split()[0] if binary.exists() else '',
                artifact=str(p.relative_to(root)), log=str(log_path.relative_to(root)),
                review=str(review_path.relative_to(root)) if review_path.exists() else None, warnings=warnings, infrastructure_error=raw.get('infrastructure_error'),
                learning_checks=meta.get('learning_checks'), exit_code=meta.get('exit_code'))

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('directory',nargs='?',default='docs/evals/margin'); parser.add_argument('--output')
    args=parser.parse_args(); root=Path(args.directory)
    directories=sorted({p.parent for pat in ['*/results.json','*/run-info.json'] for p in root.glob(pat)})
    runs=sorted([load_run(d,root) for d in directories],key=lambda r:r['started_at'] or '')
    native_path=root/'native-checks.json'
    native=json.loads(native_path.read_text()).get('observations',[]) if native_path.exists() else []
    payload=json.dumps(dict(runs=runs,categories=CATEGORIES,native=native,generated_at=dt.datetime.now(dt.timezone.utc).isoformat())).replace('<','\\u003c')
    template=Path(__file__).with_name('margin-eval-report.html').read_text()
    output=Path(args.output) if args.output else root/'report.html'
    output.write_text(template.replace('__DATA__',payload)); print(output.resolve())

if __name__=='__main__': main()
