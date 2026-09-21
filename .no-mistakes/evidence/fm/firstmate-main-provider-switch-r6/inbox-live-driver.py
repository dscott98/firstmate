import os,json,pathlib,subprocess,concurrent.futures
root=pathlib.Path.cwd(); home=root/'.test-phase-tmp/inbox-live'; home.mkdir()
env=dict(os.environ,FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'))
log=open('/home/dscott/.no-mistakes/evidence/01M32JAB16PW614MA93BBP214M/inbox-live.jsonl','w')
def call(*args):
 p=subprocess.run([str(root/'bin/fm-inbox.sh'),*args],env=env,text=True,capture_output=True); assert p.returncode==0,p.stderr
 return p.stdout
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex: responses=list(ex.map(lambda _:json.loads(call('note','--request-id','live-concurrent','--json','live capture')),range(6)))
log.write(json.dumps({'concurrent_submissions':responses})+'\n')
ids={r['id'] for r in responses}; assert len(ids)==1; ident=ids.pop()
log.write(json.dumps({'ack':call('drain','--ack',ident)})+'\n')
for args in [('note','--request-id','live-concurrent','--json','retry'),('announce','--json',ident)]:
 response=json.loads(call(*args)); log.write(json.dumps({'command':args,'response':response})+'\n'); assert response['acknowledged'] is True
assert not (home/f'state/inbox/{ident}.note').exists()
log.write(json.dumps({'reply':json.loads(call('reply','--json',ident,'captured once and handled'))})+'\n')
receipts=json.loads(call('receipts','--all-handled','--all-replies')); log.write(json.dumps({'receipts':receipts})+'\n'); assert len(receipts['replies'])==1
print('Concurrent CLI submissions returned one ID; acknowledged retries stayed handled; receipts returned the reply.')
