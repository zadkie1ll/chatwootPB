import importlib.util
from pathlib import Path
import unittest

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('watchdog', root / 'scripts/server/watchdog.py')
watchdog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watchdog)


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.containers = {name: {'running': True, 'health': 'healthy'} for name in watchdog.REQUIRED}
        self.history = {}

    def test_healthy_stack_does_not_restart(self):
        self.assertIsNone(watchdog.recovery_candidate(self.containers, self.history, 1000))

    def test_three_consecutive_failures_are_required_and_recovery_is_cooled_down(self):
        self.containers['chatwoot-web']['health'] = 'unhealthy'
        self.assertIsNone(watchdog.recovery_candidate(self.containers, self.history, 1000))
        self.assertIsNone(watchdog.recovery_candidate(self.containers, self.history, 1060))
        self.assertEqual(watchdog.recovery_candidate(self.containers, self.history, 1120), 'chatwoot-web')
        self.history['chatwoot-web']['last_restart'] = 1120
        self.assertIsNone(watchdog.recovery_candidate(self.containers, self.history, 1180))

    def test_healthy_result_clears_transient_failures(self):
        self.containers['chatwoot-web']['health'] = 'unhealthy'
        watchdog.recovery_candidate(self.containers, self.history, 1000)
        self.containers['chatwoot-web']['health'] = 'healthy'
        watchdog.recovery_candidate(self.containers, self.history, 1060)
        self.assertEqual(self.history['chatwoot-web']['failures'], 0)

    def test_database_failure_does_not_restart_applications(self):
        self.containers['postgres']['health'] = 'unhealthy'
        self.containers['chatwoot-web']['health'] = 'unhealthy'
        for now in (1000, 1060, 1120):
            self.assertIsNone(watchdog.recovery_candidate(self.containers, self.history, now))

    def test_stopped_services_are_not_restarted(self):
        self.containers['max-gateway'] = {'running': False, 'health': 'unhealthy'}
        for now in (1000, 1060, 1120):
            self.assertIsNone(watchdog.recovery_candidate(self.containers, self.history, now))

    def test_disconnected_gateway_and_stalled_queue_are_reported_even_with_healthy_containers(self):
        issues = watchdog.issues_for(self.containers, {'443': True, '18443': True}, {
            'telegram': {'connected': True}, 'max': {'connected': False},
            'incoming': {'oldest_seconds': 301}, 'workers': {'delivery': {'healthy': True, 'last_success_age': 400}}})
        self.assertIn('max:disconnected', issues)
        self.assertIn('incoming:delayed', issues)
        self.assertIn('worker:delivery', issues)
