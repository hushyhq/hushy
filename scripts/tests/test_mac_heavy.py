#!/usr/bin/env python3
"""Queued cancellation must never execute work or remove another process's lock."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

WRAPPER = Path(__file__).resolve().parents[1] / 'mac-heavy.sh'


class QueuedCancellationTests(unittest.TestCase):
    def check_cancel(self, sig, expected_code):
        with tempfile.TemporaryDirectory(prefix='hushy-heavy-cancel-') as folder:
            root = Path(folder)
            lock = root / 'foreign.lock'
            lock.mkdir()
            owner = str(os.getpid())
            (lock / 'pid').write_text(owner + '\n')
            (lock / 'label').write_text('foreign-holder\n')
            marker = root / 'must-not-run'
            env = dict(os.environ, HUSHY_HEAVY_LOCK=str(lock))
            child = subprocess.Popen(
                ['bash', str(WRAPPER), 'cancel-test', 'touch', str(marker)],
                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, start_new_session=True,
            )
            try:
                queue = Path(str(lock) + '.queue')
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    if queue.exists() and list(queue.iterdir()):
                        break
                    time.sleep(0.02)
                else:
                    self.fail('wrapper did not enqueue')
                # Wait for the wrapper's waiting message: traps are installed by then.
                self.assertIn('waiting for foreign-holder', child.stderr.readline())
                child.send_signal(sig)
                stdout, stderr = child.communicate(timeout=10)
                self.assertEqual(child.returncode, expected_code, stdout + stderr)
                self.assertFalse(marker.exists(), 'canceled work executed')
                self.assertEqual((lock / 'pid').read_text().strip(), owner)
                self.assertEqual((lock / 'label').read_text().strip(), 'foreign-holder')
                self.assertEqual(list(queue.iterdir()), [], 'own ticket leaked')
            finally:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.communicate(timeout=5)

    def test_queued_term_exits_without_running(self):
        self.check_cancel(signal.SIGTERM, 143)

    def test_queued_int_exits_without_running(self):
        self.check_cancel(signal.SIGINT, 130)


class RunLimitTests(unittest.TestCase):
    def run_wrapper(self, root, command, limit):
        env = dict(os.environ, HUSHY_HEAVY_LOCK=str(root / 'own.lock'), HUSHY_HEAVY_MAX_SECONDS=str(limit))
        return subprocess.run(['bash', str(WRAPPER), 'limit-test', *command], env=env, capture_output=True,
                              text=True, timeout=40, start_new_session=True)

    def test_job_over_the_limit_is_stopped_with_its_children_and_the_lock_is_released(self):
        with tempfile.TemporaryDirectory(prefix='hushy-heavy-limit-') as folder:
            root = Path(folder)
            child_pid = root / 'child.pid'
            started = time.monotonic()
            result = self.run_wrapper(root, ['bash', '-c', f'sleep 60 & echo $! > {child_pid}; wait'], limit=1)
            self.assertLess(time.monotonic() - started, 20)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('ran longer than 1s', result.stderr)
            self.assertFalse((root / 'own.lock').exists(), 'lock left behind')
            time.sleep(0.5)
            with self.assertRaises(ProcessLookupError):
                os.kill(int(child_pid.read_text()), 0)

    def test_job_within_the_limit_keeps_its_output_and_exit_code(self):
        with tempfile.TemporaryDirectory(prefix='hushy-heavy-limit-') as folder:
            root = Path(folder)
            result = self.run_wrapper(root, ['bash', '-c', 'echo done; exit 7'], limit=30)
            self.assertEqual(result.returncode, 7)
            self.assertEqual(result.stdout.strip(), 'done')
            self.assertFalse((root / 'own.lock').exists(), 'lock left behind')

    def test_no_limit_when_zero(self):
        with tempfile.TemporaryDirectory(prefix='hushy-heavy-limit-') as folder:
            result = self.run_wrapper(Path(folder), ['bash', '-c', 'sleep 2; exit 3'], limit=0)
            self.assertEqual(result.returncode, 3)


if __name__ == '__main__':
    unittest.main()
