import os, pathlib, tempfile, subprocess, base64, json, shutil
root=pathlib.Path.cwd(); ev=pathlib.Path('/home/dscott/.no-mistakes/evidence/01M3XTF38S4CD8T17R8TADK5B2'); scratch=pathlib.Path(tempfile.mkdtemp(prefix='.rtc-live-',dir=root)); log=[]
def run(args,env,input=None,ok=True):
 p=subprocess.run([str(x) for x in args],env=env,input=input,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 log.append('$ '+' '.join(str(x) for x in args)+'\n'+p.stdout+'exit='+str(p.returncode)+'\n')
 assert (p.returncode==0)==ok,p.stdout
 return p.stdout
def b(s): return base64.b64encode(s.encode()).decode()
try:
 env=os.environ.copy()
 for k in list(env):
  if k.startswith('FM_') or k in ('GH_TOKEN','GITHUB_TOKEN','GH_CONFIG_DIR','XDG_CONFIG_HOME','TMUX'): env.pop(k)
 account=scratch/'account'; account.mkdir(); tmp=scratch/'tmp';tmp.mkdir(); primary=scratch/'primary';primary.mkdir(); home=scratch/'task'; id='live-pr3'
 env.update(HOME=str(account),TMPDIR=str(tmp),FM_HOME=str(primary),GIT_CONFIG_NOSYSTEM='1')
 origin=scratch/'origin';run(['git','init','-q',origin],env);run(['git','-C',origin,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','--allow-empty','-qm','seed'],env)
 run([root/'bin/fm-brief.sh',id,'alpha','--mode','direct-PR','--for-home',home,'--for-root','/opt/firstmate-lab'],env)
 brief=(primary/'data'/id/'brief.md').read_text().replace('{TASK}','Validate isolated provisioning.').replace('{FIRSTMATE_SPEC}','Exercise the public CLI.')
 assert str(home/'state'/f'{id}.status') in brief and str(home/'state'/f'{id}.inbox') in brief
 (ev/'rendered-brief.md').write_text(brief)
 fields=dict(schema='fm-remote-task-provision.v1',task_id=id,kind='ship',project='alpha',origin_b64=b('file://'+str(origin)),registry_b64=b('- alpha [direct-PR] - isolated lab'),harness='pi',model='default',effort='default',brief_b64=b(brief),mode='direct-PR',yolo='off',branch_prefix_b64=b('fm/'))
 env['FM_HOME']=str(home)
 ctl=root/'bin/fm-remote-task-control.sh'
 def manifest(f): return ''.join(k+'='+v+'\n' for k,v in f.items())
 for typ,obj in [('oauth',{'type':'oauth','access':'PLANTED'}),('unknown',{'type':'unknown','key':'PLANTED'}),('extra',{'type':'api_key','key':'PLANTED','extra':'PLANTED'})]:
  f=fields.copy();f['pi_auth_b64']=b(json.dumps({'labprovider':obj}));out=run([ctl,'provision',id],env,manifest(f),False);assert 'PLANTED' not in out and not home.exists()
 f=fields.copy();f['pi_auth_b64']=b(json.dumps({'labprovider':{'type':'api_key','key':'SYNTHETIC-NOT-A-CREDENTIAL'}}))
 out=run([ctl,'provision',id],env,manifest(f));assert 'provision=created' in out
 auth=account/'.pi/agent/auth.json';assert auth.stat().st_mode&0o777==0o600
 assert (home/'config/backlog-backend').read_text().strip()=='manual'
 assert (home/'data'/id/'brief.md').read_text()==brief
 out=run([ctl,'provision',id],env,manifest(f));assert 'provision=current' in out
 run([ctl,'state','wrong-owner'],env,ok=False)
 changed=f.copy();changed['model']='other';run([ctl,'provision',id],env,manifest(changed),False)
 out=run([ctl,'state',id],env);assert out.strip()=='missing'
 updated=brief+'\nUpdated scenario instructions.\n';run([ctl,'brief-update',id],env,updated);assert (home/'data'/id/'brief.md').read_text()==updated
 bad=updated.replace(str(home/'state'/f'{id}.status'),'/another-home/state/live-pr3.status')
 run([ctl,'brief-update',id],env,bad,False);assert (home/'data'/id/'brief.md').read_text()==updated
 # Fail after the Pi credential write by cloning an absent origin; old credentials must survive.
 prior=auth.read_bytes(); failed=scratch/'failed';env['FM_HOME']=str(failed);f['brief_b64']=b(brief.replace(str(home),str(failed)));f['origin_b64']=b('file://'+str(scratch/'missing-origin'))
 run([ctl,'provision',id],env,manifest(f),False);assert auth.read_bytes()==prior and not failed.exists()
 lab=scratch/'marked-lab';run([root/'bin/fm-lab-home.sh','create',lab],env)
 env['FM_HOME']=str(lab);f['brief_b64']=b(brief.replace(str(home),str(lab)));f['origin_b64']=fields['origin_b64']
 out=run([ctl,'provision',id],env,manifest(f),False);assert 'content but no provisioning marker' in out
 log.append('Observed: exact brief bytes, manual backlog, Pi auth mode 0600, idempotence, owner/digest refusals, absent agent, atomic brief update/refusal, and credential rollback verified.\n')
finally:
 (ev/'live-cli.txt').write_text('\n'.join(log));shutil.rmtree(scratch)
