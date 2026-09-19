import os,pty,fcntl,termios,struct,subprocess,select,time,pathlib,json,re
root=pathlib.Path.cwd(); base=root/'.test-pi-tmp/live'; evidence=pathlib.Path('/home/dscott/.no-mistakes/evidence/01M2VV2ESQ723TGD987VM7517N')
env={k:v for k,v in os.environ.items() if not any(x in k for x in ['API_KEY','AUTH_TOKEN','OAUTH','BEARER'])}
env.update(PI_CODING_AGENT_DIR=str(base/'agent'),PI_OFFLINE='1',PI_TELEMETRY='0',TERM='xterm-256color',PI_PROBE_MARKER=str(base/'loaded'))
results=[]
for name,extra in [('before',[]),('approved',['--approve']),('after',[])]:
 (base/'loaded').unlink(missing_ok=True)
 master,slave=pty.openpty(); fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',32,120,0,0))
 cmd=['/home/dscott/.local/bin/pi','--offline','--no-session','--tui-mode','regular','--model','openai/gpt-4o-mini']+extra
 p=subprocess.Popen(cmd,cwd=base/'project',env=env,stdin=slave,stdout=slave,stderr=slave,start_new_session=True); os.close(slave)
 data=b''; end=time.time()+8
 while time.time()<end:
  if select.select([master],[],[],0.2)[0]:
   try: data+=os.read(master,65536)
   except OSError: break
 p.terminate()
 try:p.wait(timeout=3)
 except subprocess.TimeoutExpired:p.kill();p.wait()
 os.close(master)
 (evidence/f'pi-{name}.ansi').write_bytes(data)
 clean=re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]','',data.decode(errors='replace'))
 (evidence/f'pi-{name}.txt').write_text(clean)
 results.append(dict(scenario=name,command=' '.join(cmd),extension_loaded=(base/'loaded').exists(),output=clean[-6000:]))
(evidence/'pi-trust-results.json').write_text(json.dumps(results,indent=2));print(json.dumps(results,indent=2))
