import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "bin" / "verify"


class VerificationCliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="pixir-verify-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "site").mkdir()
        (self.root / "site/package.json").write_text('{}')
        self.bin = self.root / "tools"
        self.bin.mkdir()
        self.env = {**os.environ, 'PATH': str(self.bin) + os.pathsep + os.environ['PATH']}

    def tool(self, body):
        executable = self.bin / 'pnpm'
        executable.write_text('#!/bin/sh\n' + body)
        executable.chmod(0o700)

    def run_cli(self, *args):
        if '--output-dir' not in args:
            args = (*args, '--output-dir', str(self.root / 'evidence'))
        return subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root), '--json', *args], env=self.env, text=True, capture_output=True, timeout=15)

    def test_dry_run_has_plan_without_creating_output(self):
        output = self.root / 'evidence'
        result = self.run_cli('--scope', 'site', '--dry-run', '--output-dir', str(output))
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual([row['command'] for row in plan['plan']], [['pnpm', '--config.verifyDepsBeforeRun=error', 'check'], ['pnpm', '--config.verifyDepsBeforeRun=error', 'build']])
        self.assertFalse(output.exists())

    def test_success_persists_logs_and_manifest(self):
        self.tool("echo proof\nexit 0\n")
        result = self.run_cli('--scope', 'site', '--output-dir', str(self.root / 'evidence'))
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report['ok'])
        self.assertEqual(len(report['checks']), 2)
        self.assertTrue(all(Path(row['log']).read_text().strip() == 'proof' for row in report['checks']))
        self.assertEqual(json.loads(Path(report['manifest']).read_text()), report)

    def test_failure_is_not_green_and_dependent_build_is_not_run(self):
        self.tool("echo fixture.ts:17:failed\nexit 7\n")
        result = self.run_cli('--scope', 'site', '--show-failures')
        self.assertEqual(result.returncode, 1, result.stderr)
        report = json.loads(result.stdout)
        self.assertFalse(report['ok'])
        self.assertEqual(report['checks'][0]['exit_code'], 7)
        self.assertEqual(report['checks'][1]['status'], 'not_run')
        self.assertIn('fixture.ts:17:failed', result.stderr)

    def test_requested_missing_surface_fails_instead_of_silently_skipping(self):
        result = self.run_cli('--scope', 'monitor')
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)['error']['kind'], 'scope_unavailable')

    def test_retired_experiment_is_not_a_scope_even_if_an_old_directory_remains(self):
        (self.root / 'webmcp-canvas').mkdir()
        (self.root / 'webmcp-canvas/package.json').write_text('{}')
        result = self.run_cli('--scope', 'webmcp', '--dry-run')
        self.assertEqual(result.returncode, 2)
        self.assertIn('invalid choice', result.stderr)
        self.assertFalse((self.root / 'evidence').exists())
        result = self.run_cli('--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['coverage']['requested'], ['core', 'monitor', 'site'])
        self.assertEqual(report['scopes'], ['site'])

    def test_timeout_is_structured_and_fails(self):
        self.tool("sleep 5\n")
        result = self.run_cli('--scope', 'site', '--timeout', '0.05')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout)['checks'][0]['status'], 'timed_out')

    def release_tools(self):
        (self.root / 'mix.exs').write_text('fixture')
        (self.root / 'monitor').mkdir()
        (self.root / 'monitor/mix.exs').write_text('fixture')
        self.trace = self.root / 'executions.jsonl'
        self.env.update(VERIFY_TRACE=str(self.trace), CI='false',
                        PIXIR_MONITOR_LIFECYCLE='0',
                        PIXIR_MONITOR_BROWSER_BIN='/fixture/chrome',
                        PIXIR_MONITOR_BROWSER_EXTRA_ARGS='--fixture-argument')
        body = '''import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
row = {'name': name, 'args': sys.argv[1:], 'cwd': os.getcwd(),
       'env': {key: os.environ.get(key) for key in
               ('CI', 'PIXIR_MONITOR_LIFECYCLE', 'PIXIR_MONITOR_BROWSER_BIN',
                'PIXIR_MONITOR_BROWSER_EXTRA_ARGS', 'MIX_ENV', 'UV_OFFLINE', 'NO_COLOR')}}
with open(os.environ['VERIFY_TRACE'], 'a') as stream:
    stream.write(json.dumps(row) + '\\n')
if '--version' in sys.argv[1:] and name in ('node', 'pnpm'):
    key, default = ('VERIFY_NODE_VERSION', 'v24.17.0') if name == 'node' else ('VERIFY_PNPM_VERSION', '11.5.0')
    print(os.environ.get(key, default))
else:
    print('fixture command output stays in its log')
if os.environ.get('VERIFY_FAIL') == name + ':' + (sys.argv[1] if len(sys.argv) > 1 else ''):
    sys.exit(9)
'''
        for relative in ('tools/mix', 'tools/pnpm', 'tools/node', 'tools/uv',
                         'pixir', 'monitor/pixir-monitor'):
            executable = self.root / relative
            executable.write_text('#!' + sys.executable + '\n' + body)
            executable.chmod(0o700)

    def executions(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()]

    def test_release_rejects_wrong_frontend_node_before_application_commands(self):
        self.release_tools()
        self.env['VERIFY_NODE_VERSION'] = 'v26.3.1'
        result = self.run_cli('--release', '--scope', 'site',
                              '--output-dir', str(self.root / 'bad-node-site'))
        self.assertEqual(result.returncode, 1, result.stderr)
        report = json.loads(result.stdout)
        check = report['checks'][0]
        self.assertEqual(check['error']['kind'], 'frontend_toolchain_mismatch')
        self.assertEqual(check['toolchain']['observed'], 'v26.3.1')
        self.assertEqual(report['coverage']['completed'], [])
        self.assertTrue(all(row['status'] == 'not_run' for row in report['checks'][1:]))

    def test_release_rejects_wrong_frontend_pnpm_before_application_commands(self):
        self.release_tools()
        self.env['VERIFY_PNPM_VERSION'] = '11.6.0'
        result = self.run_cli('--release', '--scope', 'site',
                              '--output-dir', str(self.root / 'bad-pnpm-site'))
        self.assertEqual(result.returncode, 1, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['checks'][0]['status'], 'passed')
        check = report['checks'][1]
        self.assertEqual(check['error']['kind'], 'frontend_toolchain_mismatch')
        self.assertEqual(check['toolchain']['observed'], '11.6.0')
        self.assertTrue(all(row['status'] == 'not_run' for row in report['checks'][2:]))

    def test_release_dry_run_declares_frontend_version_requirements_without_execution(self):
        self.release_tools()
        result = self.run_cli('--release', '--scope', 'site', '--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)['plan']
        requirements = [row['version_requirement'] for row in plan
                        if row['scope'] == 'site' and 'version_requirement' in row]
        self.assertEqual(requirements, [{'tool': 'node', 'major': 24},
                                        {'tool': 'pnpm', 'exact': '11.5.0'}])
        self.assertFalse(self.trace.exists())

    def test_release_executes_complete_plan_and_forwards_only_child_overrides(self):
        self.release_tools()
        original_env = dict(self.env)
        result = self.run_cli('--release')
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['mode'], 'release')
        self.assertEqual(report['timeout_seconds'], 1800)
        commands = [row['command'] for row in report['checks']]
        self.assertIn(['./pixir', 'doctor', '--json'], commands)
        self.assertIn(['mix', 'docs', '--warnings-as-errors'], commands)
        self.assertIn(['uv', 'run', 'python', '-m', 'unittest', 'discover',
                       '-s', 'test', '-p', 'verify_cli_test.py'], commands)
        self.assertFalse(any('--stale' in command for command in commands))
        executions = self.executions()
        self.assertEqual(len(executions), len(report['plan']))
        monitor_test = next(row for row in executions if row['args'][:1] == ['test']
                            and row['cwd'].endswith('/monitor'))
        self.assertEqual(monitor_test['env']['CI'], 'true')
        self.assertEqual(monitor_test['env']['PIXIR_MONITOR_LIFECYCLE'], '1')
        self.assertEqual(monitor_test['env']['MIX_ENV'], 'test')
        self.assertEqual(monitor_test['env']['PIXIR_MONITOR_BROWSER_BIN'], '/fixture/chrome')
        self.assertEqual(monitor_test['env']['PIXIR_MONITOR_BROWSER_EXTRA_ARGS'], '--fixture-argument')
        core_test = next(row for row in executions if row['args'][:1] == ['test']
                         and row['cwd'] == str(self.root.resolve()))
        self.assertEqual(core_test['env']['CI'], 'false')
        self.assertEqual(core_test['env']['PIXIR_MONITOR_LIFECYCLE'], '0')
        self.assertEqual(next(row for row in executions if row['name'] == 'uv')['env']['UV_OFFLINE'], '1')
        self.assertEqual(self.env, original_env)
        for row in report['plan']:
            self.assertEqual(row['env']['NO_COLOR'], '1')
            if row['command'][0] == 'pnpm':
                self.assertEqual(row['command'][1], '--config.verifyDepsBeforeRun=error')
        monitor_plan = next(row for row in report['plan'] if row['scope'] == 'monitor'
                            and row['command'][:2] == ['mix', 'test'])
        self.assertEqual(monitor_plan['env']['PIXIR_MONITOR_LIFECYCLE'], '1')
        self.assertIn('PIXIR_MONITOR_BROWSER_BIN', monitor_plan['required_env'])
        self.assertEqual(report['coverage']['completed'], ['core', 'monitor', 'site'])
        self.assertTrue(report['coverage']['all_surfaces_completed'])
        self.assertEqual(report['readiness']['label'], 'offline_only')
        self.assertEqual(json.loads(Path(report['manifest']).read_text()), report)

    def test_release_dry_run_is_nonmutating_and_reports_unselected_scopes(self):
        self.release_tools()
        before = sorted(str(path.relative_to(self.root)) for path in self.root.rglob('*'))
        result = self.run_cli('--release', '--scope', 'monitor', '--dry-run', '--timeout', '12')
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['timeout_seconds'], 12)
        self.assertEqual(report['coverage']['requested'], ['monitor'])
        self.assertEqual(report['coverage']['executed'], [])
        self.assertEqual(report['coverage']['completed'], [])
        self.assertFalse(report['coverage']['all_surfaces_completed'])
        self.assertEqual({row['scope']: row['reason'] for row in report['coverage']['not_run']},
                         {'core': 'not_selected', 'monitor': 'dry_run',
                          'site': 'not_selected'})
        gate = next(row for row in report['plan'] if row['command'][0] == 'node')
        self.assertIn('WebSocket', gate['command'][-1])
        self.assertIn('PIXIR_MONITOR_BROWSER_BIN', gate['command'][-1])
        self.assertEqual(gate['env']['CI'], 'true')
        self.assertEqual(before, sorted(str(path.relative_to(self.root)) for path in self.root.rglob('*')))

    def test_release_quick_conflict_is_structured_without_execution_or_writes(self):
        self.release_tools()
        result = self.run_cli('--release', '--quick')
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)['error']['kind'], 'incompatible_modes')
        self.assertFalse(self.trace.exists())
        self.assertFalse((self.root / 'evidence').exists())

    def test_release_failure_blocks_only_its_scope_and_records_partial_coverage(self):
        self.release_tools()
        self.env['VERIFY_FAIL'] = 'pixir:doctor'
        result = self.run_cli('--release', '--scope', 'core', '--scope', 'site')
        self.assertEqual(result.returncode, 1, result.stderr)
        report = json.loads(result.stdout)
        self.assertFalse(report['ok'])
        failed = next(row for row in report['checks'] if row.get('exit_code') == 9)
        self.assertEqual(failed['command'], ['./pixir', 'doctor', '--json'])
        self.assertTrue(any(row['status'] == 'not_run' and row['scope'] == 'core'
                            for row in report['checks']))
        self.assertEqual(report['coverage']['executed'], ['core', 'site'])
        self.assertEqual(report['coverage']['completed'], ['site'])
        self.assertFalse(report['coverage']['all_surfaces_completed'])

    def test_release_browser_prerequisite_failure_cannot_silently_skip_monitor(self):
        self.release_tools()
        self.env['VERIFY_FAIL'] = 'node:-e'
        result = self.run_cli('--release', '--scope', 'monitor', '--scope', 'site')
        self.assertEqual(result.returncode, 1, result.stderr)
        report = json.loads(result.stdout)
        node_check = next(row for row in report['checks'] if row['command'][0] == 'node')
        self.assertEqual(node_check['exit_code'], 9)
        monitor_test = next(row for row in report['checks'] if row['scope'] == 'monitor'
                            and row['command'][:2] == ['mix', 'test'])
        self.assertEqual(monitor_test['status'], 'not_run')
        self.assertEqual(report['coverage']['completed'], ['site'])

    def test_release_absent_applications_do_not_claim_all_surface_acceptance(self):
        self.tool('case "$*" in *--version*) echo 11.5.0;; esac\nexit 0\n')
        node = self.bin / 'node'
        node.write_text('#!/bin/sh\necho v24.17.0\n')
        node.chmod(0o700)
        result = self.run_cli('--release')
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['coverage']['requested'], ['core', 'monitor', 'site'])
        self.assertEqual(report['coverage']['executed'], ['site'])
        self.assertEqual(report['coverage']['not_applicable'], ['core', 'monitor'])
        self.assertFalse(report['coverage']['all_surfaces_completed'])
        self.assertEqual(report['readiness']['status'], 'selected_scopes_passed')
        self.assertIn('live_provider_calls', report['readiness']['not_claimed'])
        self.assertIn('per_test_omission_accounting', report['readiness']['not_claimed'])

    def test_release_dry_run_disables_git_optional_index_writes(self):
        executable = self.bin / 'git'
        executable.write_text('#!' + sys.executable + '\nimport os\n'
                              'print("unlocked" if os.environ.get("GIT_OPTIONAL_LOCKS") == "0" else "locked")\n')
        executable.chmod(0o700)
        result = self.run_cli('--release', '--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['commit'], 'unlocked')
        self.assertEqual(report['working_changes'], 'unlocked')
        self.assertFalse((self.root / 'evidence').exists())

    def test_existing_quick_profile_keeps_stale_tests_and_600_second_timeout(self):
        self.release_tools()
        result = self.run_cli('--quick', '--scope', 'core')
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['mode'], 'quick')
        self.assertEqual(report['timeout_seconds'], 600)
        self.assertEqual([row['args'] for row in self.executions()],
                         [['format', '--check-formatted'], ['compile', '--warnings-as-errors'],
                          ['test', '--warnings-as-errors', '--stale']])
        self.assertTrue(all(row['env']['MIX_ENV'] == self.env.get('MIX_ENV')
                            for row in self.executions()))


if __name__ == '__main__':
    unittest.main()
