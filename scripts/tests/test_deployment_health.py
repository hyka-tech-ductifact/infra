"""Exercise deployment severity with simulated services, without Docker or SSH."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

DOCKER = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
scenario = os.environ.get('SCENARIO', '')
with open(os.environ['COMMAND_LOG'], 'a') as log:
    log.write(' '.join(args) + '\n')
if args[0] == 'compose':
    if '--environment' in args:
        print('BACKEND_PORT=8091\nFRONTEND_PORT=4201\nGRAFANA_PORT=3001\nREDIS_PASSWORD=dummy')
    if scenario == 'monitor-start' and ('pull' in args or 'up' in args) and any(s in args for s in ('prometheus', 'grafana')):
        sys.exit(1)
    if scenario == 'core-start' and 'up' in args and 'backend' in args:
        sys.exit(1)
elif args[0] == 'inspect':
    print('false' if scenario == 'monitor-down' and 'prometheus' in args[-1] else 'true')
elif args[0] == 'exec':
    if scenario == 'storage-down' and args[1].endswith('_s3'): sys.exit(1)
    if 'redis-cli' in args:
        sys.exit(1) if scenario == 'redis-down' else print('PONG')
    elif 'prometheus' in args[1]:
        if scenario == 'monitor-down': sys.exit(1)
        if 'targets' in args[-1]:
            health = 'down' if scenario == 'scrape-down' else 'up'
            print(json.dumps({'status':'success', 'data':{'activeTargets':[{
                'labels':{'job':'ductifact-api'}, 'health':health,
                'scrapeUrl':'http://app:8080/metrics', 'lastError':'lookup app: no such host' if health == 'down' else '',
                'lastScrape':'2026-11-17T14:25:05Z'}]}}))
'''
CURL = r'''#!/usr/bin/env python3
import os, sys
url = sys.argv[-1]
scenario = os.environ.get('SCENARIO', '')
if scenario == 'backend-down' and ('healthz' in url or 'readyz' in url): sys.exit(22)
if scenario == 'frontend-down' and ':4201' in url: sys.exit(22)
if scenario == 'metrics-down' and '/metrics' in url: sys.exit(22)
if scenario == 'grafana-down' and ':3001' in url: sys.exit(22)
print('{"status":"ready"}' if 'readyz' in url else 'OK')
'''


class DeploymentHealthTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for folder in ('scripts/checks', 'scripts/ops', 'bin'):
            (self.root / folder).mkdir(parents=True)
        for script in ('checks/health.sh', 'ops/deploy.sh'):
            shutil.copy2(ROOT / 'scripts' / script, self.root / 'scripts' / script)
        self.write('scripts/checks/env.sh', '#!/bin/bash\nexit 0\n')
        self.write('bin/docker', DOCKER)
        self.write('bin/curl', CURL)
        # Advance Bash's clock instead of waiting through retries in tests.
        self.write('bash_env', 'sleep() { SECONDS=$((SECONDS + 60)); }\n')
        (self.root / '.env.staging').write_text('# dummy runtime file\n')
        self.env = dict(os.environ, PATH=f'{self.root / "bin"}:{os.environ["PATH"]}',
                        BASH_ENV=str(self.root / 'bash_env'),
                        COMMAND_LOG=str(self.root / 'commands'))

    def write(self, name, text):
        path = self.root / name
        path.write_text(text)
        path.chmod(0o755)

    def run_script(self, script, scenario='', *args):
        return subprocess.run(['bash', str(self.root / 'scripts' / script), 'staging', *args],
                              env=dict(self.env, SCENARIO=scenario), text=True, capture_output=True)

    def test_monitoring_severity_in_both_modes(self):
        for scenario in ('', 'metrics-down', 'grafana-down', 'monitor-down', 'scrape-down'):
            for strict in (False, True):
                with self.subTest(scenario=scenario, strict=strict):
                    result = self.run_script('checks/health.sh', scenario, *(['--strict'] if strict else []))
                    self.assertEqual(result.returncode, int(bool(scenario) and strict), result.stdout + result.stderr)
                    self.assertEqual('::warning::' in result.stdout, bool(scenario))
                    if scenario and not strict:
                        self.assertIn('monitoring degraded', result.stdout)
                    if scenario == 'scrape-down':
                        self.assertIn('lookup app: no such host', result.stdout)

    def test_core_failures_always_fail(self):
        for scenario in ('backend-down', 'frontend-down', 'redis-down', 'storage-down'):
            for mode in ([], ['--strict']):
                with self.subTest(scenario=scenario, mode=mode):
                    result = self.run_script('checks/health.sh', scenario, *mode)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_invalid_health_option(self):
        self.assertEqual(self.run_script('checks/health.sh', '', '--unknown').returncode, 1)

    def test_deployment_startup_severity(self):
        for scenario, expected in (('', 0), ('monitor-start', 0), ('core-start', 1)):
            with self.subTest(scenario=scenario):
                result = self.run_script('ops/deploy.sh', scenario)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                if scenario == 'monitor-start':
                    self.assertIn('::warning::', result.stdout)
                commands = (self.root / 'commands').read_text()
                self.assertIn('--wait-timeout 120 postgres s3 redis backend frontend', commands)

    def test_ci_summary_and_exit_status(self):
        script = (ROOT / 'scripts/ci/deploy_remote.sh').read_text()
        pipeline = script[script.index('if ssh "${SSH_OPTIONS[@]}"'):]
        prefix = r'''
set -euo pipefail
SSH_OPTIONS=()
TARGET=test
ENVIRONMENT=staging
REMOTE_FILE=dummy.upload
ENV_FILE_NAME=.env.staging
ssh() {
  if [[ "$SCENARIO" == warning ]]; then echo '::warning::Monitoring degraded'; fi
  if [[ "$SCENARIO" == failed ]]; then return 1; fi
}
'''
        for scenario, expected, message in (('', 0, 'successfully'), ('warning', 0, 'with warnings'), ('failed', 1, 'failed')):
            with self.subTest(scenario=scenario):
                summary = self.root / 'summary'
                summary.write_text('')
                result = subprocess.run(['bash', '-c', prefix + pipeline], env=dict(self.env,
                    SCENARIO=scenario, ENV_TMP_DIR=str(self.root), GITHUB_STEP_SUMMARY=str(summary)),
                    text=True, capture_output=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertIn(message, summary.read_text())


if __name__ == '__main__':
    unittest.main()
