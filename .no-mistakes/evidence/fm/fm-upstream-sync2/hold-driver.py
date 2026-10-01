import os,subprocess,pathlib,json
root=pathlib.Path.cwd(); home=root/'.test-validation/hold-home'; evidence=pathlib.Path('/home/dscott/.no-mistakes/evidence/01M3WTMD48P6JA22314QBDEW0P')
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') and k.endswith('_OVERRIDE'))}
env['FM_HOME']=str(home);env['TMPDIR']=str(root/'.test-validation/tmp')
log=[]
def run(script,*args,ok=True):
 p=subprocess.run([str(root/'bin'/script),*args],env=env,text=True,capture_output=True)
 log.append('$ '+script+' '+repr(args)+'\n'+p.stdout+p.stderr+f'exit={p.returncode}\n')
 assert (p.returncode==0)==ok,log[-1]
 return p.stdout
try:
 run('fm-lab-home.sh','create',str(home))
 (home/'.tasks.toml').write_bytes((root/'.tasks.toml').read_bytes())
 (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
 for id in ['review-one','review-two']:
  run('fm-tasks-axi.sh','add',id,id,'--kind','scout','--repo','sample')
  (home/'state'/f'{id}.meta').write_text('kind=scout\nmode=scout\n')
 reason='Pick (north) or "south"; café 100% %28\nSecond line\\path'
 run('fm-captain-hold.sh','hold','route-call','--title','Choose route','--reason',reason,'--repo','sample','--origin','review-one')
 shown=run('fm-tasks-axi.sh','show','route-call','--full')
 value=next(x.split(': ',1)[1] for x in shown.splitlines() if x.startswith('  hold_reason: '))
 assert json.loads(value)==reason
 run('fm-tasks-axi.sh','list','--fields','hold_reason,body')
 snapshot=run('fm-fleet-snapshot.sh','--json')
 assert next(x for x in json.loads(snapshot)['backlog']['records'] if x['id']=='route-call')['hold_reason']==reason
 (evidence/'hold-snapshot.json').write_text(snapshot)
 run('fm-captain-hold.sh','hold','review-one','--reason','',ok=False)
 run('fm-captain-hold.sh','complete','review-one','review-one',ok=False)
 run('fm-captain-hold.sh','complete','review-two','route-call',ok=False)
 run('fm-captain-hold.sh','complete','review-one','route-call')
 run('fm-captain-hold.sh','verify','review-one')
 run('fm-captain-hold.sh','hold','legacy-call','--title','Legacy call','--reason','Choose later','--repo','sample')
 out=run('fm-captain-hold.sh','complete','review-two','legacy-call')
 assert 'no recorded origin' in out
finally:
 (evidence/'hold-cli.txt').write_text('\n'.join(log))
