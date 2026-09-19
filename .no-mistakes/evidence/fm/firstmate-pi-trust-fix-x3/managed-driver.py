import os,pathlib,subprocess,json,time
root=pathlib.Path.cwd(); b=root/'.test-pi-tmp/live'; e=pathlib.Path('/home/dscott/.no-mistakes/evidence/01M2VV2ESQ723TGD987VM7517N'); sock=str(root/'.pi-test.sock')
for d in ['fm/config','fm/state','fm/data/livepi','bin','pool']:(b/d).mkdir(parents=True,exist_ok=True)
(b/'fm/config/backlog-backend').write_text('manual\n')
(b/'fm/data/livepi/brief.md').write_text('# Task\n## Captain\'s intent\nVerify startup only.\n\n## Firstmate spec\nDo not run tools or change files.\n')
(b/'bin/tmux').write_text('#!/bin/sh\nexec /usr/bin/tmux -S '+sock+' "$@"\n');(b/'bin/tmux').chmod(0o755)
p=b/'project'
for args in [['init','-q'],['add','.pi'],['-c','user.name=Test','-c','user.email=test@example.invalid','commit','-qm','trust fixture']]:subprocess.run(['git','-C',str(p)]+args,check=True)
env={k:v for k,v in os.environ.items() if not any(x in k for x in ['API_KEY','AUTH_TOKEN','OAUTH','BEARER']) and k not in ['TMUX','TMUX_PANE']}
env.update(FM_HOME=str(b/'fm'),FM_SPAWN_NO_GUARD='1',FM_BACKEND='tmux',PATH=str(b/'bin')+':'+os.environ['PATH'],PI_CODING_AGENT_DIR=str(b/'agent'),PI_OFFLINE='1',PI_TELEMETRY='0',PI_PROBE_MARKER=str(b/'managed-loaded'),TREEHOUSE_ROOT=str(b/'pool'),SHELL='/bin/bash')
def tm(*args):return subprocess.run(['/usr/bin/tmux','-S',sock,*args],env=env,capture_output=True,text=True)
try:
 r=tm('-f','/dev/null','new-session','-d','-s','firstmate','-x','120','-y','32','bash --noprofile --norc'); print(r.stderr)
 tm('set-option','-g','default-command','bash --noprofile --norc')
 r=subprocess.run(['bash','bin/fm-spawn.sh','livepi',str(p),'--scout','--harness','pi','--model','openai/gpt-4o-mini'],env=env,capture_output=True,text=True,timeout=90)
 (e/'managed-spawn.txt').write_text(r.stdout+r.stderr);print('spawn',r.returncode,r.stdout,r.stderr)
 time.sleep(6)
 cap=tm('capture-pane','-p','-t','firstmate:fm-livepi','-S','-100');(e/'managed-pane.txt').write_text(cap.stdout+cap.stderr);print(cap.stdout[-4000:])
 print('extension loaded:',(b/'managed-loaded').exists())
 (e/'managed-result.json').write_text(json.dumps({'exit':r.returncode,'extension_loaded':(b/'managed-loaded').exists()},indent=2))
finally:tm('kill-server')
