import json, re

def schema_errors(value,schema,path='arguments'):
    errors=[]; typ=schema.get('type')
    valid={'object':isinstance(value,dict),'array':isinstance(value,list),'string':isinstance(value,str),'integer':isinstance(value,int) and not isinstance(value,bool),'number':isinstance(value,(int,float)) and not isinstance(value,bool),'boolean':isinstance(value,bool)}
    if typ in valid and not valid[typ]: return [path+' must be '+typ]
    if 'enum' in schema and value not in schema['enum']: errors.append(path+' not in enum')
    if isinstance(value,dict):
        for key in schema.get('required',[]):
            if key not in value: errors.append(path+'.'+key+' missing')
        for key,v in value.items():
            if key in schema.get('properties',{}): errors+=schema_errors(v,schema['properties'][key],path+'.'+key)
            elif schema.get('additionalProperties') is False: errors.append(path+'.'+key+' unknown')
    if isinstance(value,list):
        if len(value)>schema.get('maxItems',10**8): errors.append(path+' too many items')
        for i,v in enumerate(value): errors+=schema_errors(v,schema.get('items',{}),path+f'[{i}]')
    return errors

def grade(case,response,snapshot):
    message=response.get('message',{}); text=message.get('content','').strip(); errors=[]
    calls=[]
    for raw in message.get('tool_calls',[]):
        call=raw.get('function',{}); args=call.get('arguments',{})
        if isinstance(args,str):
            try: args=json.loads(args)
            except ValueError: errors.append('Malformed tool arguments'); args={}
        calls.append({'name':call.get('name'),'arguments':args})
    if not text and not calls: errors.append('No answer or tool call')
    if response.get('done') is not True: errors.append('Incomplete response')
    if response.get('done_reason')=='length': errors.append('Output budget exhausted')
    if case['kind']=='routing':
        # Same normalization as MarginAgent.normalizedCalls.
        if len(calls)>1 and all(c['name']=='create_event' for c in calls): calls=[{'name':'create_events','arguments':{'events':[c['arguments'] for c in calls]}}]
        name=calls[0]['name'] if len(calls)==1 else '(declined)' if not calls else '(multiple calls)'
        if name not in case['expected']: errors.append('Expected '+ ' / '.join(case['expected'])+'; got '+str(name))
        schema={t['function']['name']:t['function']['parameters'] for t in snapshot['tools']}
        args=calls[0]['arguments'] if len(calls)==1 else {}
        if calls:
            if name not in schema: errors.append('Tool outside registry or multiple unrelated calls')
            else: errors+=schema_errors(args,schema[name])
        if name in ('move_event','cancel_event'):
            if not args.get('title') and not args.get('original_start'): errors.append('Missing event selector')
            if name=='move_event' and not args.get('new_start') and not args.get('new_date'): errors.append('Missing move destination time/date')
        if name=='create_events':
            events=args.get('events',[])
            if not events: errors.append('Empty batch')
            for e in events:
                if not e.get('title') or not e.get('start'): errors.append('Batch event missing title/date')
        for op,key,wanted in case.get('checks',[]):
            value=args.get(key)
            if op=='eq': ok=value==wanted
            elif op=='contains': ok=isinstance(value,list) and wanted in value
            elif op=='regex': ok=isinstance(value,str) and re.search(wanted,value) is not None
            elif op=='absent_or_empty': ok=value in (None,[],{},'')
            elif op=='events':
                ok=isinstance(value,list) and len(value)==len(wanted)
                if ok:
                    ok=all(sum(str(e.get('start','')).startswith(date) and title in str(e.get('title','')).lower().replace('’',"'") and e.get('all_day') is True for e in value)==1 for date,title in wanted)
            else: raise ValueError('Unknown assertion '+op)
            if not ok: errors.append(f'{key}: expected {op} {wanted!r}, got {value!r}')
        # No invented emails on any event, including nested batches.
        context=case['prompt']+' '+json.dumps(case.get('context',[]))
        supplied=set(re.findall(r'[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}',context.lower()))
        emitted=set(re.findall(r'[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}',json.dumps(args).lower()))
        if emitted-supplied: errors.append('Invented attendee email')
        return errors,{'tool':name,'arguments':args,'text':text}
    if calls: errors.append('Unexpected tool calls')
    if case['kind']=='learning':
        clean=re.sub(r'^```(?:json)?\s*|\s*```$','',text).strip()
        try:
            entries=json.loads(clean); errors+=schema_errors(entries,snapshot['learning_schema'])
            if not isinstance(entries,list): return errors+['Not a preference list'], {'text':text}
            if case['empty'] and entries: errors.append('Retained content that must not become memory/soul')
            if not case['empty'] and not any(e.get('kind') in case['kinds'] and e.get('key') in case['keys'] for e in entries if isinstance(e,dict)): errors.append('Required preference not extracted')
            for e in entries:
                if not isinstance(e,dict): continue
                quote=e.get('evidence',''); value=e.get('value','')
                if not 8<=len(quote)<=300 or quote not in case['prompt']: errors.append('Evidence not an exact user quote')
                if not 1<=len(value)<=300: errors.append('Invalid preference length')
            return errors,{'text':text,'entries':entries}
        except (ValueError,TypeError): return errors+['Invalid learning JSON'],{'text':text}
    for pattern in case.get('patterns',[]):
        if not re.search(pattern,text): errors.append('Missing required fact: '+pattern)
    for pattern in case.get('forbidden',[]):
        if re.search(pattern,text): errors.append('Forbidden unsupported content: '+pattern)
    if case['kind']=='research':
        if len(text.split())>180: errors.append('Research brief exceeds 180 words')
        paragraphs=[s for s in text.splitlines() if s.strip()]
        for paragraph in paragraphs:
            refs=re.findall(r'\[(\d+)\]',paragraph)
            if not refs or any(not 1<=int(r)<=case['source_count'] for r in refs): errors.append('Paragraph missing valid source citations')
    return errors,{'text':text}
