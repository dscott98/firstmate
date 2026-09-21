import os,json,pathlib,subprocess,select,time
root=pathlib.Path.cwd(); base=root/'.test-phase-tmp'; evidence=pathlib.Path('/home/dscott/.no-mistakes/evidence/01M32JAB16PW614MA93BBP214M')
with (evidence/'live-guards.jsonl').open('w') as log:
 for case in ['worker','missing-pin','missing-auth']:
  home=base/case
  for p in ['state','config','pi']: (home/p).mkdir(parents=True,exist_ok=True)
  if case!='missing-pin': (home/'config/supervision-branch-model').write_text('openai-codex/gpt-5.6-sol\n')
  env={'PATH':os.environ['PATH'],'HOME':str(home),'PI_CODING_AGENT_DIR':str(home/'pi'),'FM_HOME':str(home),'FM_STATE_OVERRIDE':str(home/'state'),'FM_CONFIG_OVERRIDE':str(home/'config'),'FM_ROOT_OVERRIDE':str(root),'PI_TELEMETRY':'false','TMPDIR':str(base)}
  if case=='worker': env['FM_TASK_ID']='isolated-test-worker'
  p=subprocess.Popen(['pi','--mode','rpc','--offline','--approve','--no-session','--no-context-files','--no-extensions','-e',str(root/'.pi/extensions/fm-primary-turnend-guard.ts')],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
  (home/'state/.lock').write_text(str(p.pid)+'\n')
  try:
   p.stdin.write(json.dumps({'id':case,'type':'prompt','message':'/fm-openrouter-sol'})+'\n'); p.stdin.flush()
   deadline=time.monotonic()+20; notice=None
   while time.monotonic()<deadline:
    if not select.select([p.stdout],[],[],1)[0]: continue
    line=p.stdout.readline()
    if not line: break
    event=json.loads(line); log.write(json.dumps({'case':case,'event':event})+'\n'); log.flush()
    if event.get('method')=='notify': notice=event; break
   assert notice, (case,'no notice')
   expected={'worker':'only the top-level','missing-pin':'pin supervision','missing-auth':'not configured'}[case]
   assert expected in notice['message'],notice
   print(case+': '+notice['message'])
  finally:
   p.terminate(); p.communicate(timeout=10)
