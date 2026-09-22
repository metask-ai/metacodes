"""Neutral loopback-only probe. No paid/provider traffic or benchmark payloads.

pkill uses a runtime UUID that exists only in this probe's child argv; the
controller argv never contains it. No existing service names are targeted.
"""
import argparse, hashlib, http.server, json, pathlib, subprocess, tempfile, threading, uuid

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bundle',type=pathlib.Path,required=True,help='Explicit path to the pinned artifact bundle; no provider credentials are used')
bundle=parser.parse_args().bundle.resolve()
binary=bundle/'bin/metacodes'
root=pathlib.Path(tempfile.mkdtemp(prefix='metacodes-neutral-probe-'))

def sse(obj): return ('data: '+json.dumps(obj)+'\n\n').encode()

def run_case(kind, via_stdin=False):
    case=root/(kind+('-stdin' if via_stdin else '-argv')); case.mkdir()
    home=case/'home'; (home/'.metacodes').mkdir(parents=True)
    work=case/'work'; work.mkdir(); target=work/'sample.txt'; target.write_text('ordinary text\n->needle\n')
    token='mcneutral'+uuid.uuid4().hex
    requests=[]
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body=json.loads(self.rfile.read(int(self.headers['Content-Length']))); requests.append(body)
            turn=len(requests)
            blocks=[{'type':'thinking','thinking':'NEUTRAL_REASONING_'+str(turn),'signature':'neutral-signature'}]
            if kind=='grep' and turn<=3:
                pat=['no_match_'+token,'->needle','ordinary'][turn-1]
                blocks.append({'type':'tool_use','id':'probe_'+str(turn),'name':'Grep','input':{'path':str(target),'pattern':pat,'output_mode':'content'}})
            elif kind=='signal' and turn==1:
                command='pkill -f '+token+'; printf neutral_done'
                blocks.append({'type':'tool_use','id':'probe_signal','name':'Bash','input':{'command':command,'description':'Stop only unique neutral probe marker','timeout':5000}})
            else: blocks.append({'type':'text','text':'NEUTRAL_DONE'})
            data=sse({'type':'message_start','message':{'id':'neutral','role':'assistant','model':'neutral-model','usage':{'input_tokens':1,'output_tokens':0}}})
            for i,b in enumerate(blocks):
                start=dict(b)
                if b['type']=='tool_use': start['input']={}
                if b['type']=='thinking': start={'type':'thinking','thinking':''}
                data+=sse({'type':'content_block_start','index':i,'content_block':start})
                if b['type']=='tool_use': data+=sse({'type':'content_block_delta','index':i,'delta':{'type':'input_json_delta','partial_json':json.dumps(b['input'])}})
                if b['type']=='thinking':
                    data+=sse({'type':'content_block_delta','index':i,'delta':{'type':'thinking_delta','thinking':b['thinking']}})
                    data+=sse({'type':'content_block_delta','index':i,'delta':{'type':'signature_delta','signature':b['signature']}})
                data+=sse({'type':'content_block_stop','index':i})
            data+=sse({'type':'message_delta','delta':{'stop_reason':'tool_use' if any(b['type']=='tool_use' for b in blocks) else 'end_turn'},'usage':{'output_tokens':20}})
            data+=sse({'type':'message_stop'})
            self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(data)));self.end_headers()
            self.wfile.write(data)
        def log_message(self,*a): pass
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    config={'schema_version':1,'custom_providers':{'neutral-proxy':{'display_name':'Neutral local mock','auth':{'kind':'api_key_header','header':'x-api-key'},'env_aliases':[{'name':'NEUTRAL_ROUTE_TOKEN','kind':'api_key','canonical':True}],'endpoint_policy':{'require_tls':False},'channels':[{'id':'mock','base_url':'http://127.0.0.1:'+str(server.server_port),'protocol':'anthropic_messages'}],'models':[{'request_model_id':'neutral-model'}]}}}
    (home/'.metacodes/config.json').write_text(json.dumps(config))
    env={'PATH':'/usr/local/bin:/usr/bin:/bin','HOME':str(home),'LANG':'C.UTF-8','METACODES_PROVIDER':'neutral-proxy','NEUTRAL_ROUTE_TOKEN':'nonsecret-mock','METACODES_NO_PROBE':'1','METACODES_LOG':'*:warn','METACODES_KG_TRANSPORT':'cli-exclusive','METACODES_KG_STORE':str(home/'kg'),'METACODES_KG_BIN':str(bundle/'bin/tinykg'),'METACODES_FORMAL_KERNEL_PATH':str(bundle/'libexec/metacodes-formal-kernel')}
    env['METACODES_FORMAL_KERNEL_SHA256']=hashlib.sha256((bundle/'libexec/metacodes-formal-kernel').read_bytes()).hexdigest()
    prompt='Neutral local tool test. Unique inert service label: '+token+'. Follow the supplied mock tool plan.'
    cmd=[str(binary),'--model','neutral-model','--permission','bypassPermissions','--no-theme','--json','--stream-json']
    cmd+=['-'] if via_stdin else ['-p',prompt]
    try:
        result=subprocess.run(cmd,input=prompt if via_stdin else None,cwd=work,env=env,text=True,capture_output=True,timeout=45,start_new_session=True)
        events=[]
        for line in result.stdout.splitlines():
            try: events.append(json.loads(line))
            except ValueError: pass
        response={'kind':kind,'via_stdin':via_stdin,'returncode':result.returncode,'requests':len(requests),'tool_results':[e for e in events if e.get('type')=='tool_result'],'final_results':[e for e in events if e.get('type')=='result'],'thinking_events':sum(e.get('type')=='thinking' for e in events),'history_thinking_counts':[sum(b.get('type')=='thinking' for m in r.get('messages',[]) for b in (m.get('content') if isinstance(m.get('content'),list) else [])) for r in requests],'stderr':result.stderr[-3000:]}
        (case/'stdout.jsonl').write_text(result.stdout);(case/'requests.json').write_text(json.dumps(requests))
    finally: server.shutdown();server.server_close();thread.join()
    return response

print(json.dumps({'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'evidence_root':str(root),'cases':[run_case('grep'),run_case('signal'),run_case('signal',True)]},ensure_ascii=False))

