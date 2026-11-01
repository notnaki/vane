#!/usr/bin/env python3
"""Hosted605c adaptation of reviewed local controllers; no test implementation changes."""
import sys
sys.dont_write_bytecode=True
from pathlib import Path
from datetime import datetime,timezone
import hashlib,importlib.util,json,math,os,re,subprocess,tempfile,time
ROOT=Path.cwd().resolve();OUT=Path(os.environ['VANE_DIAGNOSTIC_DIR']);STATUS=OUT/'runtime-status.json'
HELPERS=Path(__file__).resolve().parent;sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
PACKET=Path(os.environ['VANE_BUILD_MANIFEST']);EXPECTED=os.environ['VANE_BUILD_MANIFEST_SHA'];assert sha(PACKET)==EXPECTED
runtime=json.loads(PACKET.read_text());data=json.loads((HELPERS/'f17-spell605-slots.json').read_text());mode=os.environ['VANE_JOB_KIND'];assert mode in ('controls','observation')
plan={'head':os.environ['GITHUB_SHA'],'workspace':str(ROOT),'source':{'path':str(ROOT/'Tests/VaneTests/PasswordAutofillTests.swift')},'bundle':{'path':str(ROOT/runtime['test_bundle']),'binary':str(ROOT/runtime['test_binary'])},'cohorts':data['cohorts'],'execution':{'clear_environment':data['clear_environment'],'environment':{'VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT':'180'}}}
assert runtime['head']==plan['head'] and runtime['source']==data['source']=='605caadc1f8c8df99fc833cd7dfd191c702dbd9a'
spec=importlib.util.spec_from_file_location('owned_wrapper',ROOT/'scripts/run-native-tests.py');w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
STATUS.write_text(json.dumps({'mode':mode,'source':data['source'],'head':plan['head'],'current_runtime_only_not_historical':True,'F17_fixed':False},indent=2)+'\n')
def update(**items):
    state=json.loads(STATUS.read_text());state.update(items);state['updated_at']=datetime.now(timezone.utc).isoformat();STATUS.write_text(json.dumps(state,indent=2)+'\n')
def integrity():
    assert sha(PACKET)==EXPECTED
    assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()==plan['head']
    assert subprocess.check_output(['git','status','--porcelain','--untracked-files=no'],text=True)==''
    assert not (ROOT/'.build').is_symlink() and (ROOT/'.build').resolve()==ROOT/'.build'
    assert sha(os.environ['VANE_RUNTIME_ARCHIVE'])==runtime['archive_sha256']==os.environ['VANE_RUNTIME_ARCHIVE_SHA']
    for file,digest in runtime['source_pins'].items():assert sha(ROOT/file)==digest,file
    for file,digest in runtime['files'].items():
        live=ROOT/file;assert live.is_file() and not live.is_symlink() and live.resolve()==live and sha(live)==digest,file
        assert live.stat().st_mode & 0o7777==runtime['file_modes'][file],file
    for file,target in runtime['links'].items():
        live=ROOT/file;assert live.is_symlink() and os.readlink(live)==target and live.resolve().is_relative_to(ROOT/'.build'),file
    for component in runtime['components']:
        live=ROOT/component
        actual={str(p.relative_to(ROOT)) for p in live.rglob('*') if p.is_file() or p.is_symlink()} if live.is_dir() else {component}
        expected={p for p in runtime['files'] if p==component or p.startswith(component+'/')}
        expected|={p for p in runtime['links'] if p==component or p.startswith(component+'/')}
        assert actual==expected,'Runtime component leaf inventory changed '+component
    return {'head':plan['head'],'source':data['source'],'binary_sha256':sha(ROOT/runtime['test_binary']),'all_runtime_code_resource_files_match':True,'description_path':str(ROOT/runtime['description']),'description_sha256':sha(ROOT/runtime['description']),'metadata_drift_permitted':False,'clean_tracked_sources':True,'current_runtime_only_not_historical':True}
def checkpoint(stage):
    description=ROOT/runtime['description']
    if description.is_file():(OUT/('description.'+stage+'.json')).write_bytes(description.read_bytes())
    snapshot=integrity();(OUT/('integrity.'+stage+'.json')).write_text(json.dumps(snapshot,indent=2)+'\n')
    return snapshot
checkpoint('before-discovery')
clean_env=dict(os.environ)
for key in data['clear_environment']:clean_env.pop(key,None)
with (OUT/'inventory.raw.txt').open('xb') as stdout,(OUT/'inventory.stderr.txt').open('xb') as stderr:
    listed=subprocess.run(['swift','test','--build-system','native','list','--skip-build'],env=clean_env,stdout=stdout,stderr=stderr)
checkpoint('after-discovery');assert listed.returncode==0
inventory=[line.strip() for line in (OUT/'inventory.raw.txt').read_text().splitlines() if line.strip() and line.strip()!='Native test host bootstrap: beforeAppKit=true, configured=true']
assert len(inventory)==len(set(inventory))==data['inventory']['count']
assert all(re.fullmatch(r'[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+/[^\s/]+',line) for line in inventory)
canonical='\n'.join(sorted(inventory));assert hashlib.sha256(canonical.encode()).hexdigest()==data['inventory']['sha256'];(OUT/'inventory.canonical.txt').write_text(canonical)
attempt_slots=data['controls'] if mode=='controls' else [dict(data['observation'],attempt=int(os.environ['VANE_OBSERVATION_INDEX']))]
for slot in attempt_slots:
    ids=slot['selected'];assert all(case in inventory for case in ids)
    pattern='^(?:'+'|'.join(re.escape(case) for case in ids)+')$'
    assert sorted(case for case in inventory if re.search(pattern,case))==sorted(ids)
    slot.update(argv=['python3','scripts/run-native-tests.py','--build-system','native','--skip-build','--jobs','1','--filter',pattern],raw_log=str(OUT/(('control-' if mode=='controls' else 'original18-')+str(slot['attempt'])+'.log')),result_json=str(OUT/(('control-' if mode=='controls' else 'original18-')+str(slot['attempt'])+'.result.json')))
schedule=[{'attempt':slot['attempt'],'cohort':slot['cohort'],'status':'NOT RUN'} for slot in attempt_slots];(OUT/'execution-plan.json').write_text(json.dumps(schedule,indent=2)+'\n')
smoke_env=dict(clean_env,VANE_APPKIT_LOOP_SMOKE='1',VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT='90')
with (OUT/'smoke.log').open('xb') as stream:
    smoke=subprocess.run(['python3','scripts/run-native-tests.py','--build-system','native','--skip-build','--jobs','1','--filter','^VaneTests[.]NativeApplicationLoopSmokeTests/testOwnedLoopAdmitsAsyncWorkAndStops$'],env=smoke_env,stdout=stream,stderr=subprocess.STDOUT)
checkpoint('after-smoke');smoke_text=(OUT/'smoke.log').read_text();assert smoke.returncode==0 and 'AppKit loop smoke: delayedHeartbeat=true, completed=true' in smoke_text and 'Native suite primary status=0; cleanup status=0' in smoke_text
assert not re.search(r'^\*\*\* Signal [0-9]+:',smoke_text,re.M)
assert all(not Path(slot['raw_log']).exists() and not Path(slot['result_json']).exists() for slot in attempt_slots)
sys.path.insert(0,str(HELPERS));from spell_trace_validation import validate,validate_original18
validate_spell_trace=validate if mode=='controls' else validate_original18
all_results=[]
def descendant(pid,parent):
 seen=set()
 while pid>1 and pid not in seen:
  if pid==parent:return True
  seen.add(pid);r=subprocess.run(['/bin/ps','-p',str(pid),'-o','ppid='],capture_output=True,text=True).stdout.strip()
  if not r:return False
  pid=int(r)
 return False
for slot in attempt_slots:
 n=slot['attempt'];schedule_entry=next(x for x in schedule if x['attempt']==n);schedule_entry['status']='RUNNING';(OUT/'execution-plan.json').write_text(json.dumps(schedule,indent=2)+'\n');log=Path(slot['raw_log']);result_path=Path(slot['result_json']);audit=OUT/f'attempt-{n}-audit';audit.mkdir(exist_ok=False);manifests=audit/'observed-manifests';manifests.mkdir();before=integrity();assert not log.exists() and not result_path.exists();started=time.time();(audit/'description.before.json').write_bytes(Path(before['description_path']).read_bytes());tmp=Path(tempfile.gettempdir()).resolve();preexisting={str(p) for p in tmp.glob('vane-native-retirement-*')};records={};contract={};events=[]
 def observe(error):
  message=str(error);now=(time.time()-started)*1000;old=next((e for e in events if e['message']==message),None)
  if old:old['last_ms']=now;old['count']+=1;return
  cause=error.__cause__;events.append({'message':message,'first_ms':now,'last_ms':now,'count':1,'cause_type':type(cause).__name__ if cause else None,'cause_errno':getattr(cause,'errno',None)})
 def collect(parent):
  dirs=[Path(contract['directory'])] if contract else [p for p in tmp.glob('vane-native-retirement-*') if str(p) not in preexisting]
  for directory in dirs:
   try:
    c=w.read_private_json(directory/'contract.json')
    if contract and c['token']!=contract['token']:continue
    for path in directory.glob('*.json'):
     if path.name in ('contract.json','complete.json'):continue
     try:
      raw=w.read_private_json(path)
      if 'host' not in raw:continue
      data=w.validate_record(raw,c['token']);host=data['host']
      if Path(host['testBundlePath']).resolve()!=Path(plan['bundle']['path']).resolve() or host['start']/1_000_000<started:continue
      live=w.process_identity(host['pid'])
      if not contract:
       if live is None or live['start']!=host['start'] or not descendant(host['pid'],parent):continue
       contract.update(directory=str(directory),token=c['token'],launcher_pid=parent)
      if str(directory)!=contract['directory']:continue
      key=(host['pid'],host['start']);old=records.get(key)
      if live is not None and live['start']==host['start'] and os.path.realpath(live['path'])!=os.path.realpath(host['path']):raise ValueError('recorded host executable mismatch')
      records[key]={'manifest':data,'source_file':path.name,'first_observed_live':old['first_observed_live'] if old else live,'first_seen_ms':old['first_seen_ms'] if old else (time.time()-started)*1000,'same_contract':True,'directory':str(directory)};dest=manifests/path.name;dest.write_text(json.dumps(data,indent=2)+'\n');os.chmod(dest,0o600)
     except (FileNotFoundError,json.JSONDecodeError,PermissionError):continue
    complete=directory/'complete.json'
    if complete.exists():
     dest=manifests/'complete.json';dest.write_text(complete.read_text());os.chmod(dest,0o600)
   except (FileNotFoundError,json.JSONDecodeError,PermissionError):continue
 environment=dict(os.environ)
 for key in plan['execution']['clear_environment']:environment.pop(key,None)
 environment.update(plan['execution']['environment']);environment.update(slot['environment'])
 for key in slot['unset_environment']:assert key not in environment,'Off-mode environment contaminated'
 with log.open('xb') as stream:
  child=subprocess.Popen(slot['argv'],cwd=ROOT,env=environment,stdout=stream,stderr=subprocess.STDOUT);launcher={'pid':child.pid,'identity':w.process_identity(child.pid),'argv':slot['argv']};(audit/'launch-record.json').write_text(json.dumps({'launcher':launcher,'started_at':datetime.now(timezone.utc).isoformat(),'pre_hashes':before,'preexisting_manifest_directories_excluded':sorted(preexisting)},indent=2)+'\n');update(original18_observation1_active_attempt=n,task_owned_processes=[launcher]);last=0
  while child.poll() is None:
   try:collect(child.pid)
   except Exception as error:observe(error)
   if time.monotonic()-last>1:
    (audit/'live-progress.json').write_text(json.dumps({'launcher':launcher,'host_records':list(records.values()),'contract':contract,'observer_observations':events},indent=2)+'\n');last=time.monotonic()
   time.sleep(0.02)
  code=child.wait()
 try:collect(child.pid)
 except Exception as error:observe(error)
 raw_bytes=log.read_bytes();warning=b"warning: '--build-system native' has been deprecated and will be removed in a future release; please report an issue at https://github.com/swiftlang/swift-package-manager/issues if you are unable to adopt the default build system.\n";normalized=raw_bytes.replace(warning,b'');normalized_log=log.with_suffix('.normalized.log');assert not normalized_log.exists();normalized_log.write_bytes(normalized);text=normalized.decode('utf-8',errors='replace');errors=[]
 try:
  (audit/'description.after.json').write_bytes(Path(before['description_path']).read_bytes());after=integrity()
 except Exception as error:after={'error':str(error)};errors.append('postrun integrity '+str(error))
 starts=[a+'/'+b for a,b in re.findall(r"Test Case '-\[([^ ]+) ([^ ]+)\]' started\.",text)];finishes=re.findall(r"Test Case '-\[([^ ]+) ([^ ]+)\]' (passed|failed|skipped) \(",text);completed=[a+'/'+b for a,b,state in finishes];outcomes={}
 for a,b,state in finishes:outcomes.setdefault(a+'/'+b,[]).append(state)
 ids=slot['selected'];retirement='VaneTests.NativeFixtureRetirementTests/testRetireManifest';expected=ids+[retirement]
 if starts!=expected:errors.append('case start list/order/duplicates differ from frozen cohort plusfreshretirement')
 if completed!=expected:errors.append('case completion list/order/duplicates differ from frozen cohort plusfreshretirement')
 for case in expected:
  if outcomes.get(case)!=['passed']:errors.append('case not passed once '+case)
 assertions=[line for line in text.splitlines() if re.search(r'error: -\[',line)]
 if assertions:errors.append('native assertion records present')
 summary=re.findall(r'Native suite primary status=(-?\d+); cleanup status=(-?\d+)',text);primary,cleanup=map(int,summary[0]) if len(summary)==1 else (-999,-999)
 if (primary,cleanup,code)!=(0,0,0):errors.append('primary/cleanup/wrapper not0/0/0')
 if re.search(r'^\*\*\* Signal|^Fatal error:|^UNVERIFIED native fixture retirement|^NATIVE PRIMARY TIMEOUT',text,re.I|re.M):errors.append('fatal/timeout/unverified marker')
 trace=[];samples={};context=[]
 for match in re.finditer(r'F17_CONTINUATION case=("(?:[^"\\]|\\.)*") phase=(\S+) uptime=([\d.]+) ([^\n]*)',text):
  try:case_name=json.loads(match[1])
  except Exception:errors.append('Malformed diagnostic case tag');continue
  alias=re.fullmatch(r'-\[(?:VaneTests\.)?PasswordAutofillTests (\w+)\]',case_name)
  if alias:case_name='-[VaneTests.PasswordAutofillTests '+alias[1]+']'
  trace.append({'case':case_name,'phase':match[2],'uptime':float(match[3]),'state':match[4]})
 if 'phase=diagnostic-overflow' in text:errors.append('Diagnostic overflow; attribution incomplete')
 if plan['cohorts'][slot['cohort']]['trace_cases'] and not trace:errors.append('No case-tagged diagnostic records')
 for record in trace:
  if not math.isfinite(record['uptime']):errors.append('Nonfinite diagnostic time')
  name=record['case'];match=re.fullmatch(r'-\[VaneTests\.PasswordAutofillTests (\w+)\]',name)
  if not match or 'VaneTests.PasswordAutofillTests/'+match[1] not in ids:errors.append('Foreign or malformed diagnostic case '+name)
 for method, requirements in plan['cohorts'][slot['cohort']]['trace_cases'].items():
  paths=requirements['paths'];name='-[VaneTests.PasswordAutofillTests '+method+']';rows=[r for r in trace if r['case']==name];phases={}
  for row in rows:phases[row['phase']]=phases.get(row['phase'],0)+1
  samples[method]=phases
  if not errors:
   for phase in ['sdk-request-document-before-guard','sdk-request-returned','owner-sdk-request-before-guard']:
    if phases.get(phase,0)!=len(paths):errors.append('Missing/duplicate request phase '+method+' '+phase)
   if phases.get('username-processing-admitted',0)!=requirements['username_acks']:errors.append('Missing/duplicate processed-ACK admission '+method)
   for phase in ['sdk-request-document-before-guard','sdk-request-returned']:
    for path in paths:
     if sum(r['phase']==phase and r['state'].startswith('path='+path+' ') for r in rows)!=1:errors.append('Missing/duplicate path phase '+method+' '+path+' '+phase)
   if requirements.get('requires_caught_premature_admission'):
    if any(r['state'].startswith('path=password ') for r in rows):errors.append('DOM-only caught-control navigated to password')
    tag='VaneTests.PasswordAutofillTests '+method
    block=re.search(re.escape("Test Case '-["+tag+"]' started.")+r'(.*?)'+re.escape("Test Case '-["+tag+"]' passed ("),text,re.S)
    if block is None or 'PrematureFillAdmission()' not in block[1]:errors.append('Missing actual caught premature-admission counterexample '+method)
 context=[r for r in trace if r['phase'].startswith('owner-')]
 spell_trace=validate_spell_trace(text,slot);errors.extend(spell_trace['validation_errors'])
 exits=[]
 for item in records.values():
  h=item['manifest']['host']
  try:
   live=w.process_identity(h['pid']);gone=live is None or live['start']!=h['start'];exits.append({'host':h,'verified_exited':gone,'current_kernel_identity':live})
   if not gone:errors.append('owned native host remains alive')
   first=item['first_observed_live']
   if first is None or first['start']!=h['start'] or os.path.realpath(first['path'])!=os.path.realpath(h['path']):errors.append('first live host identity not verified')
  except Exception as error:errors.append('host exit/identity uncertain '+str(error))
 if not any(i['source_file'].startswith('host-') for i in records.values()) or not any(i['source_file']=='cleanup-host.json' for i in records.values()):errors.append('primary and cleanup records notbothcaptured')
 if not contract or Path(contract['directory']).exists():errors.append('current contract removal notverified')
 receipt=manifests/'complete.json';expected_ids=sorted({entry['storeID'].lower() for item in records.values() if item['source_file'].startswith('host-') for entry in item['manifest']['profiles']});receipt_matches=receipt.exists() and bool(contract) and json.loads(receipt.read_text())=={'schema':1,'token':contract['token'],'retiredIDs':expected_ids}
 if not receipt_matches:errors.append('same-token exact owned cleanup receipt notcaptured/matched')
 cleanup_verified=cleanup==0 and len(exits)==2 and all(e['verified_exited'] for e in exits) and bool(contract) and not Path(contract['directory']).exists() and receipt_matches;resolved=[]
 for event in events:
  message=event['message'];match=re.fullmatch(r'cannot verify test-host (?:identity|executable) pid=(\d+)',message);reason=None
  if match and cleanup_verified:
   matching=[i for i in records.values() if i['manifest']['host']['pid']==int(match[1]) and i['first_observed_live'] is not None and i['first_seen_ms']<=event['first_ms']]
   if len(matching)==1:reason='Previously captured exactlive launch nowkernelverifiedexited; canonicalcleanup and receipt verified'
  if cleanup_verified and event['cause_errno']==2 and message=='cannot open private manifest: '+str(Path(contract['directory'])/'contract.json'):reason='Exactcurrentcontract deleted aftercanonical verifiedcleanup; sametokenreceipt captured'
  if cleanup_verified and event['cause_errno']==2:
   matching_files=[i for i in records.values() if message=='cannot open private manifest: '+str(Path(contract['directory'])/i['source_file']) and i['first_observed_live'] is not None and i['first_seen_ms']<=event['first_ms']]
   if len(matching_files)==1:reason='Previously captured exact same-token private host file deleted after canonical cleanup; exact live identity, kernel exit and receipt verified'
  if reason:resolved.append({**event,'resolution':reason})
  else:errors.append('unresolved observer error '+message)
 classification='PASS: scoped hosted observation/control only; original F17 cause/CI repair not established' if not errors else 'FAILED/INCONCLUSIVE: STOP remaining slots'
 result={'attempt':n,'packet_sha256':EXPECTED,'head':plan['head'],'log':str(log),'log_sha256':sha(log),'normalized_log':str(normalized_log),'normalized_log_sha256':sha(normalized_log),'exact_warning_removals':raw_bytes.count(warning),'launcher':launcher,'wrapper_exit':code,'primary':primary,'cleanup':cleanup,'pre_hashes':before,'post_hashes':after,'case_starts':starts,'case_completions':completed,'outcomes':outcomes,'assertion_records':assertions,'trace':trace,'spell_trace':spell_trace,'diagnostic_phase_summary':samples,'owner_records':context,'host_records':list(records.values()),'contract':contract,'host_exits':exits,'receipt_path':str(receipt),'receipt_matches':receipt_matches,'owned_backend_count':len(expected_ids),'observer_observations':events,'observer_resolutions':resolved,'validation_errors':errors,'classification':classification,'canonical_cleanup_verified':cleanup_verified,'F17_fixed':False};result_path.write_text(json.dumps(result,indent=2)+'\n');short={'attempt':n,'result':str(result_path),'log':str(log),'primary':primary,'cleanup':cleanup,'passed_selected':sum(outcomes.get(case)==['passed'] for case in ids),'diagnostic_phase_summary':samples,'validation_errors':errors,'canonical_cleanup_verified':cleanup_verified,'host_exits':[{'pid':x['host']['pid'],'start':x['host']['start'],'verified_exited':x['verified_exited']} for x in exits]};all_results.append(short);(OUT/'attempt-summary.json').write_text(json.dumps(all_results,indent=2)+'\n');update(original18_observation1_attempt_results=all_results,original18_observation1_active_attempt=None,task_owned_processes=[] if cleanup_verified else [launcher],readiness=f'Observer controls5 attempt{n} '+classification+'; hosted result preserved');print(json.dumps(short,indent=2),flush=True)
 schedule_entry.update(status='FAILED/INCONCLUSIVE' if errors else 'PASSED',primary=primary,cleanup=cleanup);(OUT/'execution-plan.json').write_text(json.dumps(schedule,indent=2)+'\n')
 if errors:break

complete=len(all_results)==len(attempt_slots) and all(not result['validation_errors'] for result in all_results)
summary={'mode':mode,'source':data['source'],'head':plan['head'],'complete':complete,'completed_slots':len(all_results),'planned_slots':len(attempt_slots),'results':all_results,'remaining_NOT_RUN':[x for x in schedule if x['status']=='NOT RUN'],'current_runtime_only_not_historical':True,'F17_fixed':False,'canonical_ownership_receipts_preserved':True}
(OUT/'job-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
if not complete:sys.exit('STOP scoped hosted605c diagnostic; dependent jobs NOT RUN. Preserve first failure/uncertainty; no retry or repair claim.')
