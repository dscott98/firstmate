import os, pathlib, subprocess, tempfile, shutil
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/dscott/.no-mistakes/evidence/01M37S0E7KF003RA6WTRHD093G')
base='3512e63e20d5ba90eb70798b57189417fbbc6d6c'
target='d31fdfee5b61197c7da58e73d2dee5d73aac58f1'
upstream='9296f9b9d2566797b9a9aecaa5956bb8e471d2cd'
log=[]
def run(*args,env=None):
 p=subprocess.run(args,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=env,check=True)
 return p.stdout.strip()
lab=pathlib.Path(tempfile.mkdtemp(prefix='.activation-test-',dir=root))
try:
 bundle=lab/'history.bundle'
 run('git','bundle','create',str(bundle),'HEAD')
 origin=lab/'origin.git'; home=lab/'home'
 run('git','init','--bare',str(origin))
 run('git','-C',str(origin),'fetch',str(bundle),'HEAD:refs/heads/main')
 run('git','-C',str(origin),'symbolic-ref','HEAD','refs/heads/main')
 run('git','clone',str(origin),str(home))
 run('git','-C',str(home),'reset','--hard',upstream)
 env={k:v for k,v in os.environ.items() if not k.startswith('FM_')}
 env.update(FM_ROOT_OVERRIDE=str(home),FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'),FM_CONFIG_OVERRIDE=str(home/'config'))
 def update(label):
  out=run('bash',str(root/'bin/fm-update.sh'),env=env)
  log.extend([label,out,'HEAD: '+run('git','-C',str(home),'rev-parse','HEAD')])
  return out
 run('git','-C',str(origin),'update-ref','refs/heads/main',base)
 assert 'skipped: diverged' in update('PRE-MERGE: upstream home must refuse fork without ancestry')
 assert run('git','-C',str(home),'rev-parse','HEAD')==upstream
 run('git','-C',str(origin),'update-ref','refs/heads/main',target)
 assert 'firstmate: updated' in update('MERGED: upstream home fast-forwards to customized fork')
 assert run('git','-C',str(home),'rev-parse','HEAD')==target
 assert run('git','-C',str(home),'rev-parse','HEAD^{tree}')==run('git','rev-parse',base+'^{tree}')
 log.append('Installed tree equals pre-merge customized fork tree: '+run('git','-C',str(home),'rev-parse','HEAD^{tree}'))
 for c in [upstream,base,'ca91de1']:
  run('git','-C',str(home),'merge-base','--is-ancestor',c,'HEAD')
 log.append('Upstream tip, token-efficiency commit, and folder-trust commit all retained as ancestors.')
 assert 'already current' in update('REPEAT: update is idempotent')
 run('git','-C',str(home),'reset','--hard',upstream)
 with (home/'README.md').open('a') as f: f.write('\nlocal unsaved test work\n')
 before=(home/'README.md').read_bytes()
 assert 'skipped: dirty working tree' in update('DIRTY: local edits block activation without data loss')
 assert run('git','-C',str(home),'rev-parse','HEAD')==upstream
 assert (home/'README.md').read_bytes()==before
 log.append('Dirty HEAD and edited file bytes preserved.')
finally:
 shutil.rmtree(lab)
 (evidence/'activation-transcript.txt').write_text('\n\n'.join(log)+'\n')
print('\n\n'.join(log))
