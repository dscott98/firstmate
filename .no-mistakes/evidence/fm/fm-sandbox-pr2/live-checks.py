import os, pathlib, tempfile, subprocess, shutil, signal, time, json
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/dscott/.no-mistakes/evidence/01M3X897SXMJW3QPYZ6N5FTSEE')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.', dir=root))
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('NO_MISTAKES_GATE',)}
env['FM_HOME']=str(lab)
worker=None
log=open(evidence/'live-cli.log','w')
def run(args, expected=None, contains=None, extra=None):
    e=env.copy(); e.update(extra or {})
    p=subprocess.run(args,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
    log.write('$ '+ ' '.join(map(str,args))+'\n'+p.stdout+f'[exit {p.returncode}]\n'); log.flush()
    if expected is not None: assert p.returncode==expected, p.stdout
    if contains: assert contains in p.stdout, p.stdout
    return p
base='''kind=ship
window=remote:validation
endpoint_task_id=validation
placement=sandbox
remote_kind=task
remote_host=fm-pr2-validation.invalid
remote_root=/opt/firstmate
remote_home=/home/agent/fm-home
remote_backend=tmux
remote_target=firstmate:fm-validation
worktree=/home/agent/fm-home/projects/unlanded
harness=codex
'''
try:
    run(['bash','bin/fm-lab-home.sh','create',str(lab)],0)
    meta=lab/'state/validation.meta'; meta.write_text(base)
    for args in [['fm-peek.sh','validation'],['fm-peek.sh','remote:validation'],['fm-send.sh','validation','please continue'],['fm-send.sh','validation','--key','Enter'],['fm-control.sh','validation','interrupt'],['fm-control.sh','validation','exit'],['fm-teardown.sh','validation']]:
        run(['bash','bin/'+args[0],*args[1:]],1,'not supported')
        assert meta.read_text()==base
    run(['bash','bin/fm-crew-state.sh','validation'],0,'not proof of death')
    assert not (lab/'state/validation.inbox').exists()
    log.write('Record preserved byte-for-byte; no steering inbox created.\n')
    for key,value,needle in [('remote_root','/opt/firstmate/','inside its code root'),('remote_root','/','overlapping'),('remote_host','-oProxyCommand=evil','unsafe'),('remote_kind','secondmate','remote_kind=task'),('endpoint_task_id','other','endpoint_task_id=validation')]:
        record=base
        if value=='/opt/firstmate/': record=record.replace('remote_home=/home/agent/fm-home','remote_home=/opt/firstmate/home')
        record='\n'.join(key+'='+value if line.startswith(key+'=') else line for line in record.splitlines())+'\n'
        meta.write_text(record)
        run(['bash','bin/fm-on.sh','validation','fm-remote-doctor.sh','--profile','task'],1,needle)
    meta.write_text(base)
    run(['bash','bin/fm-on.sh','validation','fm-remote-doctor.sh','--profile','task'],255,'Could not resolve hostname')
    (lab/'data/secondmates.md').write_text('- validation - test (host: fm-pr2-validation.invalid; root: /opt/firstmate; home: /home/agent/fm-home; scope: validation; projects: alpha; added 2026-10-01)\n')
    run(['bash','bin/fm-on.sh','validation','fm-remote-doctor.sh'],1,'ambiguous route')
    meta.write_text('kind=secondmate\nwindow=remote:validation\nendpoint_task_id=validation\nremote_host=fm-pr2-validation.invalid\nremote_root=/opt/firstmate\nhome=/home/agent/fm-home\nworktree=/home/agent/fm-home\nharness=codex\n')
    run(['bash','bin/fm-on.sh','validation','fm-remote-doctor.sh'],255,'Could not resolve hostname')
    run(['bash','bin/fm-crew-state.sh','validation'],0,'unknown')
    account=lab/'account'; (account/'.local/bin').mkdir(parents=True)
    (account/'.local/bin/treehouse').symlink_to(shutil.which('treehouse'))
    de={'HOME':str(account)}
    run(['bash','bin/fm-remote-doctor.sh','--profile','task'],1,'check herdr-server=skip:',de)
    we=env.copy(); we.update(de); we['FM_ROOT_OVERRIDE']=str(root)
    with open(evidence/'live-worker.log','w') as wlog:
        worker=subprocess.Popen(['bash','bin/fm-remote-job-worker.sh'],env=we,stdout=wlog,stderr=subprocess.STDOUT,start_new_session=True)
        for _ in range(100):
            if (account/'.firstmate/remote-job/worker.ready').exists(): break
            time.sleep(.05)
        run(['bash','bin/fm-remote-doctor.sh','--profile','task'],0,'ok: remote task readiness confirmed on this host',de)
    log.write('LIVE CHECKS COMPLETED\n')
finally:
    if worker:
        try: os.killpg(worker.pid,signal.SIGTERM); worker.wait(timeout=5)
        except ProcessLookupError: pass
        except subprocess.TimeoutExpired: os.killpg(worker.pid,signal.SIGKILL); worker.wait()
    shutil.rmtree(lab)
    log.close()
