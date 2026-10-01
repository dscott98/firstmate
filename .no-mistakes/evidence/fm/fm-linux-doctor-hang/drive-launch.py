import subprocess, os, time, json
from pathlib import Path
root=Path.cwd()
env=os.environ.copy()
env['FM_HERDR_LAB_STATE_DIR']=str(root/'.test-herdr-lab-state')
for k in ['HERDR_ENV','HERDR_PANE_ID','HERDR_TAB_ID','HERDR_WORKSPACE_ID','HERDR_SOCKET_PATH','HERDR_SESSION']:
    env.pop(k,None)
lab=str(root/'bin/fm-herdr-lab.sh')
def call(*args):
    p=subprocess.run(['bash',lab,*args],env=env,text=True,capture_output=True,timeout=20)
    print('lab',*args,'exit',p.returncode,p.stdout.strip(),p.stderr.strip(),flush=True)
    assert p.returncode==0
    return p.stdout
try:
  for variant in ['base','target']:
    session='fm-lab-capture-'+variant+'-'+str(os.getpid())
    call('provision',session)
    call('stop',session)
    try:
        script='. bin/fm-backend.sh; fm_backend_source herdr; '
        if variant=='base': script+='. bin/backends/.test-herdr-base.sh; '
        script+='fm_backend_herdr_server_ensure "$1" >/dev/null 2>&1; rc=$?; echo ensure_exit=$rc; exit "$rc"'
        for attempt in range(1 if variant=='base' else 2):
            started=time.monotonic()
            p=subprocess.Popen(['bash','-c',script,'driver',session],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            try:
                out,_=p.communicate(timeout=5)
                print(variant,'cold' if attempt==0 else 'already-running','capture EOF',round(time.monotonic()-started,3),'seconds',out.strip(),flush=True)
                assert variant=='target' and p.returncode==0
            except subprocess.TimeoutExpired:
                print(variant,'capture has no EOF after 5 seconds; caller poll=',p.poll(),flush=True)
                assert variant=='base'
            status=json.loads(call('run',session,'status','--json'))
            assert status['server']['running'] is True
            if variant=='base':
                call('stop',session)
                out,_=p.communicate(timeout=5)
                print('base capture released only after stopping server:',out.strip(),flush=True)
    finally:
        call('teardown',session)
finally:
  (root/'bin/backends/.test-herdr-base.sh').unlink()
  (root/'.test-herdr-lab-state').rmdir()
