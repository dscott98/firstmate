import os, pathlib, tempfile, subprocess, shutil
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/dscott/.no-mistakes/evidence/01M3XFH4YKHBNVD3N72N6PPSEW')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.fm-route-lab-',dir=root))
env=os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('TMUX','HERDR_SESSION'): env.pop(key,None)
env['FM_HOME']=str(lab)
log=open(evidence/'live-cli.log','w')
def run(args, expect=None, contains=None, custom=None):
    p=subprocess.run(args,cwd=root,env=custom or env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
    log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+f'EXIT={p.returncode}\n\n');log.flush()
    if expect is not None: assert p.returncode==expect,(args,p.returncode,p.stdout)
    if contains: assert contains in p.stdout,(args,p.stdout)
    return p
try:
    run(['bin/fm-lab-home.sh','create',str(lab)],0)
    meta=lab/'state/probe.meta'
    fields=dict(kind='ship',window='remote:probe',endpoint_task_id='probe',placement='sandbox',remote_kind='task',remote_host='fm-route-unreachable.invalid',remote_root='/opt/firstmate',remote_home='/home/agent/fm-home',remote_backend='tmux',remote_target='firstmate:fm-probe',worktree=str(lab/'unlanded'),sandbox_provider='pve-sandbox',sandbox_name='sbx-probe',sandbox_profile='default')
    (lab/'unlanded').mkdir(); (lab/'unlanded/keep').write_text('unlanded evidence\n')
    def write(changes={}): meta.write_text(''.join(f'{k}={v}\n' for k,v in (fields|changes).items()))
    write(); original=meta.read_bytes()
    for args in [['fm-peek.sh','probe'],['fm-peek.sh','fm-probe'],['fm-peek.sh','remote:probe'],['fm-send.sh','probe','hello'],['fm-send.sh','remote:probe','hello'],['fm-send.sh','probe','--key','Enter'],['fm-control.sh','probe','interrupt'],['fm-control.sh','probe','exit'],['fm-control.sh','probe','relaunch','--note','recover'],['fm-teardown.sh','probe'],['fm-teardown.sh','probe','--force']]:
        run(['bin/'+args[0]]+args[1:],1,'not supported for a sandbox task')
        assert meta.read_bytes()==original
        assert (lab/'unlanded/keep').read_text()=='unlanded evidence\n'
    run(['bin/fm-crew-state.sh','probe'],0,'state: unknown')
    log.write('PRESERVED: sandbox metadata and unlanded file unchanged after every refused operation.\n')
    for changes,reason in [({'remote_host':'-oProxyCommand=bad'},'unsafe'),({'remote_root':'relative'},'not absolute'),({'remote_home':'/opt/firstmate/nested'},'inside its code root'),({'remote_kind':'secondmate'},'remote_kind=task'),({'endpoint_task_id':'other'},'endpoint_task_id=probe')]:
        write(changes);run(['bin/fm-on.sh','probe','fm-remote-doctor.sh','--profile','task'],1,reason)
    write()
    (lab/'data/secondmates.md').write_text('- probe - collision (host: fm-other.invalid; root: /opt/firstmate; home: /home/agent/fm-home; scope: testing; projects: alpha; added 2026-10-01)\n')
    run(['bin/fm-on.sh','probe','fm-remote-doctor.sh','--profile','task'],1,'ambiguous')
    (lab/'data/secondmates.md').unlink()
    run(['bin/fm-on.sh','probe','fm-remote-doctor.sh','--profile','task'],255,'Could not resolve hostname')
    (lab/'data/secondmates.md').write_text('- mate - remote (host: fm-route-unreachable.invalid; root: /opt/firstmate; home: /home/agent/fm-home; scope: testing; projects: alpha; added 2026-10-01)\n')
    (lab/'state/mate.meta').write_text('kind=secondmate\nwindow=remote:mate\nremote_host=fm-route-unreachable.invalid\nremote_root=/opt/firstmate\nhome=/home/agent/fm-home\n')
    run(['bin/fm-on.sh','mate','fm-remote-doctor.sh'],255,'Could not resolve hostname')
    run(['bin/fm-crew-state.sh','mate'],0,'unknown-remote')
    doctor_env=env.copy(); doctor_env['HOME']=str(lab); doctor_env['FM_REMOTE_JOB_STATE_ROOT']=str(lab/'remote-job')
    p=run(['bin/fm-remote-doctor.sh','--profile','task'],custom=doctor_env)
    assert 'required tmux=' in p.stdout and 'optional tasks-axi=' in p.stdout and 'check herdr-server=skip:' in p.stdout
    assert 'required herdr=' not in p.stdout
    run(['bin/fm-remote-doctor.sh','--profile','invalid'],2,custom=doctor_env)
    log.write('LIVE CHECKS COMPLETE; doctor gaps reflect this unprovisioned lab, no repair requested.\n')
finally:
    shutil.rmtree(lab)
    log.close()
