#!/usr/bin/env python3
"""Release contract tests. Docker, HTTP, Git, and time are faked in a temp checkout.
No Docker socket, database, or network is used. Run: python3 tools/tests/test_release.py
"""
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MOCK = r"""#!/usr/bin/env python3
import datetime, json, os, sys
from pathlib import Path
name=Path(sys.argv[0]).name; args=sys.argv[1:]
root=Path(os.environ['MOCK_ROOT']); clock=root/'clock'
now=int(clock.read_text()); epoch=lambda t: datetime.datetime.fromtimestamp(t,datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
mode=os.environ.get('CASE','')
if name=='date':
 print(now if args==['+%s'] else (epoch(now).replace('Z','.250000000Z') if '%N' in args[-1] else epoch(now))); sys.exit()
if name=='sleep': clock.write_text(str(now+int(args[0]))); sys.exit()
if name=='git': sys.exit()
if name=='curl':
 url=args[-1]
 if 'api.github.com' in url:
  print(json.dumps(dict(tag_name=url.split('/')[-1],draft=False,prerelease=mode=='prerelease',published_at=epoch(now))));sys.exit()
 if url.endswith('/health'):
  if mode.startswith('early_delivery') and (root/'deployed').exists() and not (root/'health_waited').exists():
   clock.write_text(str(now+5)); (root/'health_waited').touch()
  sys.exit(0)
 if mode=='metrics_invalid': print('invalid');sys.exit()
 regression=mode=='operational_transient' and now-int(os.environ['MOCK_EPOCH'])==120
 meso='warning' if regression or mode=='meso_warning' or (mode=='meso_transient' and now-int(os.environ['MOCK_EPOCH'])==120) else 'healthy'
 print(json.dumps({'generatedAt':epoch(now if mode!='stale' else now-500),
  'redLights':{'ingestFreshness':{'status':'critical' if regression or mode=='nws_failed' else 'healthy','recentFailureCount':0},
   'spcMesoIngest':{'status':meso,'lastAttemptStatus':'failed' if regression else 'succeeded','lastAttemptAgeSeconds':700 if meso=='warning' else 20,'recentFailureCount':1 if regression else 0},
   'pipelineBacklogAge':{'status':'warning' if regression else 'healthy','pendingTargetDispatchCount':2 if regression else 0,'pendingNotificationDispatchCount':0},
   'stuckClaimedRows':{'status':'warning' if regression else 'healthy','count':1 if regression else 0}},
  'deliveryKPIs':{'apnsDeliverySuccessRate':{'sentCount':6,'failedCount':2},'sendNoOpRateByReason':{}}}));sys.exit()
if name!='docker': sys.exit(90)
with (root/'calls').open('a') as f: f.write(json.dumps(args)+'\n')
if mode=='docker_denied': sys.exit(13)
if args[0]=='version': print('29');sys.exit()
if args[0]=='manifest': sys.exit()
if args[:2]==['image','inspect']:
 print('sha256:new|'+'a'*40+'|'+os.environ['ARCUS_SIGNAL_IMAGE_TAG']+'|ghcr.io/justinrooks/arcus-signal@sha256:'+'b'*64);sys.exit()
new=(root/'deployed').exists()
if args[0]=='inspect':
 if mode=='inspect_denied': sys.exit(13)
 template=args[2];service=args[-1].removesuffix('_id')
 if '.State.Running' in template: print('true|'+('healthy' if service in ('postgres','redis') else 'none'))
 elif '.Config.Image' in template:
  print('ghcr.io/justinrooks/arcus-signal:'+ ((root/'deployed').read_text() if new else 'v1.4.1') if service in ('api','worker') else service+':stable')
 elif '.Image' in template: print('sha256:unexpected' if mode=='image_changed' and new else ('sha256:new' if new else 'sha256:old'))
 else: print('' if mode=='missing_gate' else 'false')
 sys.exit()
if args[0]=='compose':
 if args[1:]==['version']: print('5');sys.exit()
 args=args[5:]  # --project-directory PATH --env-file PATH
 command=args[0]
 if command=='config':
  env={'VAPOR_ENV':'production','MESO_NOTIFICATIONS_ENABLED':'false','DATABASE_URL':'postgres://arcus:fake@postgres:5432/arcus_signal','REDIS_URL':'redis://redis:6379'}
  print(json.dumps({'services':{'api':{'image':'ghcr.io/justinrooks/arcus-signal:'+os.environ['ARCUS_SIGNAL_IMAGE_TAG'],'environment':env},
   'worker':{'image':'ghcr.io/justinrooks/arcus-signal:'+os.environ['ARCUS_SIGNAL_IMAGE_TAG'],'environment':env},
   'postgres':{'environment':{'POSTGRES_DB':'arcus_signal'}}}}));sys.exit()
 if command=='ps':
  if mode!='missing_service': print(args[-1]+'_id')
  sys.exit()
 if command=='exec':
  data=sys.stdin.read()
  if 'pg_restore' in args: sys.exit(1 if mode=='bad_backup' else 0)
  if any(a.startswith('since=') for a in args):
   counts={'sentCount':1 if mode=='delivery_observed' else 0,'failedCount':1 if mode=='delivery_failed' else 0,'ambiguousSentCount':0,'ambiguousFailedCount':0}
   if (root/'completions').exists():
    params=dict(a.split('=',1) for a in args if a.startswith(('since=','attributable_since=')))
    timestamp=lambda t: datetime.datetime.fromisoformat(t.replace('Z','+00:00')).timestamp()
    since=timestamp(params['since']); attributable=timestamp(params['attributable_since'])
    for completion in json.loads((root/'completions').read_text()):
     if since <= completion <= now:
      counts['sentCount' if completion >= attributable else 'ambiguousSentCount']+=1
   print(json.dumps(counts))
  else: print(json.dumps({'passed':mode!='bad_schema'}))
  sys.exit()
 if command=='pull': sys.exit()
 if command=='run':
  if '--no-build' in args: sys.exit(92) # compose run has no --no-build option
  if 'migrate' in args and mode=='migration_failed': print('SECRET_SENTINEL');sys.exit(7)
  if mode=='binary_failed' and 'migrate' not in args: sys.exit(9)
  sys.exit()
 if command=='up':
  (root/'deployed').write_text(os.environ['ARCUS_SIGNAL_IMAGE_TAG'])
  if mode.startswith('early_delivery'):
   # Two overlap completions, one in the verification second, and a completion
   # after verification but before the installer's delayed HTTP checks finish.
   completions=[now-1,now+2,now+5.1]
   if mode=='early_delivery_mixed': completions.append(now+7)
   (root/'completions').write_text(json.dumps(completions))
   clock.write_text(str(now+5))
  sys.exit()
sys.exit(91)
"""

class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='arcus-release-contract-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copy(ROOT/'install', self.root/'install')
        for name in ('release-preflight.sh','release-snapshot.sh','release-observe.sh'):
            (self.root/'tools').mkdir(exist_ok=True)
            shutil.copy(ROOT/'tools'/name, self.root/'tools'/name)
        shutil.copytree(ROOT/'tools/lib', self.root/'tools/lib')
        shutil.copytree(ROOT/'tools/sql', self.root/'tools/sql')
        (self.root/'.env').touch()
        (self.root/'docker-compose.yml').touch()
        (self.root/'bin').mkdir()
        driver=self.root/'bin/mock';driver.write_text(MOCK);driver.chmod(0o755)
        for name in ('docker','curl','git','date','sleep'): (self.root/'bin'/name).symlink_to(driver)
        self.epoch=1800000000
        (self.root/'clock').write_text(str(self.epoch))
        backup=self.root/'backup.dump';backup.write_bytes(b'fake archive')
        os.utime(backup,(self.epoch,self.epoch))
        self.env=dict(os.environ,PATH=str(self.root/'bin')+':'+os.environ['PATH'],
            TMPDIR=str(self.root),MOCK_ROOT=str(self.root),MOCK_EPOCH=str(self.epoch),
            ARCUS_RELEASE_BACKUP_FILE=str(backup))
        self.env.pop('CASE',None)

    def run_script(self, name, *args, case='', expected=0):
        p=subprocess.run([str(self.root/name),*args],env=dict(self.env,CASE=case),text=True,capture_output=True,timeout=20)
        self.assertEqual(p.returncode,expected,p.stderr+'\n'+p.stdout)
        self.assertNotIn('SECRET_SENTINEL',p.stdout+p.stderr)
        return p

    def deploy(self, case='', expected=0):
        self.run_script('install','v1.4.2',case=case,expected=expected)
        records=list(self.root.glob('arcus-release-*/deployment.json'))
        self.assertEqual(len(records),1)
        return records[0],json.loads(records[0].read_text())

    def calls(self):
        return (self.root/'calls').read_text()

    def test_successful_deployment(self):
        _,r=self.deploy()
        self.assertEqual(r['status'],'passed')
        self.assertEqual(r['migrationState'],'completed')
        self.assertEqual(r['imageID'],'sha256:new')
        self.assertIn('schema_verification',r['completedPhases'])
        self.assertEqual(r['deliveryEvidenceStartAt'],r['applicationStartAt'])
        self.assertTrue(r['workerVerifiedAt'])
        calls=[json.loads(x) for x in self.calls().splitlines()]
        migration=[x for x in calls if 'migrate' in x]
        self.assertEqual(len(migration),1)
        self.assertIn('production',migration[0])
        self.assertNotIn('sudo',self.calls())
        self.assertLess(self.calls().index('ldd'),self.calls().index('migrate'))

    def test_migration_failure_is_uncertain_and_stops(self):
        _,r=self.deploy(case='migration_failed',expected=4)
        self.assertEqual(r['failedPhase'],'migrations')
        self.assertEqual(r['migrationState'],'uncertain')
        self.assertFalse(r['applicationStarted'])
        self.assertFalse((self.root/'deployed').exists())

    def test_schema_failure_stops_before_application_start(self):
        _,r=self.deploy(case='bad_schema',expected=4)
        self.assertEqual(r['failedPhase'],'schema_verification')
        self.assertEqual(r['migrationState'],'completed')
        self.assertFalse((self.root/'deployed').exists())

    def test_binary_failure_stops_before_migration(self):
        _,r=self.deploy(case='binary_failed',expected=4)
        self.assertEqual(r['failedPhase'],'packaged_binaries')
        self.assertNotIn('migrate',self.calls())

    def test_docker_error_is_not_service_missing(self):
        p=self.run_script('tools/release-snapshot.sh','--json',case='docker_denied',expected=3)
        r=json.loads(p.stdout)
        self.assertEqual(r['collectionStatus'],'failed')
        self.assertNotIn('services',r)

    def test_missing_service_is_an_infrastructure_failure(self):
        p=self.run_script('tools/release-snapshot.sh','--json',case='missing_service',expected=4)
        r=json.loads(p.stdout)
        self.assertEqual(r['collectionStatus'],'passed')
        self.assertEqual(r['services']['api']['health'],'missing')

    def test_missing_gate_fails_closed(self):
        self.run_script('tools/release-preflight.sh','v1.4.2',case='missing_gate',expected=4)
        self.assertNotIn('migrate',self.calls())

    def test_unhealthy_or_invalid_metrics_never_pass(self):
        for mode in ('metrics_invalid','stale','nws_failed'):
            with self.subTest(mode=mode):
                p=self.run_script('tools/release-snapshot.sh','--json',case=mode,expected=1)
                self.assertEqual(json.loads(p.stdout)['status'],'attention')

    def test_tags_rejected_before_docker(self):
        for tag in ('1.4.2','v01.4.2','latest','v1.4.2-beta','v1.4.2;false'):
            with self.subTest(tag=tag): self.run_script('install',tag,expected=2)
        self.assertFalse((self.root/'calls').exists())

    def test_prerelease_and_bad_backup_block_deployment(self):
        for mode in ('prerelease','bad_backup'):
            with self.subTest(mode=mode): self.run_script('tools/release-preflight.sh','v1.4.2',case=mode,expected=4)
        self.assertNotIn('migrate',self.calls())

    def test_backup_directory_default_discovery_and_staleness(self):
        self.env.pop('ARCUS_RELEASE_BACKUP_FILE')
        self.env['ARCUS_RELEASE_BACKUP_DIR']=str(self.root)
        self.run_script('tools/release-preflight.sh','v1.4.2')
        os.utime(self.root/'backup.dump',(self.epoch-90000,self.epoch-90000))
        self.run_script('tools/release-preflight.sh','v1.4.2',expected=4)

    def test_concurrent_installer_is_rejected(self):
        with (self.root/'install').open() as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            self.run_script('install','v1.4.2',expected=4)
        self.assertFalse((self.root/'calls').exists())

    def test_observation_schedule_and_no_traffic(self):
        path,_=self.deploy()
        self.run_script('tools/release-observe.sh','--deployment',str(path))
        r=json.loads(next(path.parent.glob('observation.*/observation.json')).read_text())
        self.assertEqual([s['elapsedSeconds'] for s in r['snapshots']],[0,120,420,720])
        self.assertEqual(r['deliveryConfidence'],'unobserved')
        self.assertEqual(r['status'],'passed')

    def test_delivery_evidence_and_transient_spc_warning(self):
        path,_=self.deploy()
        for mode,confidence in [('delivery_observed','observed'),('delivery_failed','degraded'),('meso_transient','unobserved')]:
            (self.root/'clock').write_text(str(self.epoch))
            expected=1 if mode=='delivery_failed' else 0
            p=self.run_script('tools/release-observe.sh','--deployment',str(path),case=mode,expected=expected)
            r=json.loads(p.stdout)
            self.assertEqual(r['deliveryConfidence'],confidence)

    def test_inspection_error_is_distinct_from_missing_service(self):
        p=self.run_script('tools/release-snapshot.sh','--json',case='inspect_denied',expected=3)
        r=json.loads(p.stdout)
        self.assertEqual(r['error'],'docker_inspection_failed')
        self.assertNotIn('services',r)

    def test_observation_detects_replaced_image_even_with_same_tag(self):
        path,_=self.deploy()
        self.run_script('tools/release-observe.sh','--deployment',str(path),case='image_changed',expected=4)
        r=json.loads(next(path.parent.glob('observation.*/observation.json')).read_text())
        self.assertEqual(r['status'],'failed')
        self.assertEqual(r['snapshots'][0]['error'],'deployed_image_changed')
        self.assertFalse(r['complete'])

    def test_unresolved_spc_age_warning_is_reported(self):
        path,_=self.deploy()
        p=self.run_script('tools/release-observe.sh','--deployment',str(path),case='meso_warning',expected=1)
        self.assertIn('recheck after the next attempt',p.stdout)
        finding=next(item for item in json.loads(p.stdout)['findings'] if item['key']=='spc_ingest')
        self.assertEqual(finding['state'],'unresolved')
        self.assertIsNone(finding['recoveredAt'])

    def test_transient_regressions_are_retained_as_recovered(self):
        path,_=self.deploy()
        p=self.run_script('tools/release-observe.sh','--deployment',str(path),case='operational_transient')
        summary=json.loads(p.stdout)
        self.assertEqual(summary['status'],'passed')
        self.assertEqual(summary['concerns'],[])
        findings={item['key']:item for item in summary['findings']}
        self.assertTrue({'nws_ingest','dispatch_backlog','stuck_claims','spc_ingest'} <= findings.keys())
        report=json.loads(next(path.parent.glob('observation.*/observation.json')).read_text())
        for item in findings.values():
            self.assertEqual(item['state'],'recovered')
            self.assertFalse(item['preexisting'])
            self.assertEqual([o['scheduledOffsetSeconds'] for o in item['observations']],[120])
            self.assertEqual(item['recoveredAt'],report['snapshots'][2]['capturedAt'])
        self.assertEqual([sample['operationalStatus'] for sample in report['snapshots']],
                         ['healthy','degraded','healthy','healthy'])

    def test_delivery_between_startup_and_finished_is_not_lost(self):
        path,deployment=self.deploy(case='early_delivery_mixed')
        self.assertLess(deployment['workerVerifiedAt'],deployment['finishedAt'])
        p=self.run_script('tools/release-observe.sh','--deployment',str(path))
        summary=json.loads(p.stdout)
        self.assertEqual(summary['deliveryConfidence'],'observed')
        self.assertEqual(summary['deliveryEvidence']['sentCount'],1)
        self.assertEqual(summary['deliveryEvidence']['ambiguousSentCount'],2)
        report=json.loads(next(path.parent.glob('observation.*/observation.json')).read_text())
        self.assertEqual(report['deliveryEvidenceStartAt'],deployment['applicationStartAt'])
        self.assertEqual(report['snapshots'][0]['deliverySince'],deployment['applicationStartAt'])
        self.assertEqual(report['snapshots'][0]['postDeployDelivery']['sentCount'],1)

    def test_overlap_only_delivery_is_ambiguous_not_observed(self):
        path,_=self.deploy(case='early_delivery_ambiguous')
        p=self.run_script('tools/release-observe.sh','--deployment',str(path))
        summary=json.loads(p.stdout)
        self.assertEqual(summary['deliveryConfidence'],'ambiguous')
        self.assertEqual(summary['deliveryEvidence']['sentCount'],0)
        self.assertEqual(summary['deliveryEvidence']['ambiguousSentCount'],2)

    def test_older_records_retain_early_delivery_conservatively(self):
        path,deployment=self.deploy(case='early_delivery_mixed')
        del deployment['workerVerifiedAt']
        del deployment['deliveryEvidenceStartAt']
        path.write_text(json.dumps(deployment))
        p=self.run_script('tools/release-observe.sh','--deployment',str(path))
        summary=json.loads(p.stdout)
        self.assertEqual(summary['deliveryConfidence'],'ambiguous')
        self.assertEqual(summary['deliveryEvidence']['ambiguousSentCount'],3)

    def test_attribution_boundary_cannot_precede_evidence(self):
        self.run_script('tools/release-snapshot.sh','--since','2026-10-15T17:00:00.250Z',
                        '--attributable-since','2026-10-15T17:00:00.100Z',expected=2)
        self.assertFalse((self.root/'calls').exists())

    def test_partial_deployment_cannot_be_observed_as_success(self):
        path,_=self.deploy(case='bad_schema',expected=4)
        self.run_script('tools/release-observe.sh','--deployment',str(path),expected=4)

if __name__=='__main__': unittest.main(verbosity=2)
