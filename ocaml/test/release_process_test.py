#!/usr/bin/env python3
"""Exercise bounded capture with live producers and observable direct-child reap."""

import contextlib
import importlib.util
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import traceback
import unittest
from unittest import mock


sys.dont_write_bytecode = True
SOURCE = Path(__file__).resolve().parent.parent / "tools/bounded_process.py"
SPEC = importlib.util.spec_from_file_location("bounded_process", SOURCE)
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
STREAM_BOUND = 128 * 1024
DEADLINE = 0.2
PRODUCER_LIFETIME = 3
PRODUCER = """
import os, sys, time
mode, output, errors, status, lifetime = sys.argv[1:]
output, errors = int(output), int(errors)
while output or errors:
    if output:
        output -= os.write(1, b'O' * min(output, 8192))
    if errors:
        errors -= os.write(2, b'E' * min(errors, 8192))
if mode == 'closed':
    os.close(1)
    os.close(2)
if mode != 'done':
    time.sleep(float(lifetime))
raise SystemExit(int(status))
"""


class PrimaryFault(Exception):
    pass


class CleanupFault(Exception):
    pass


class Capture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="symphony-capture-")
        self.base = Path(self.temp.name)
        self.processes = []
        self.selectors = []
        self.popen = subprocess.Popen
        self.selector = selectors.DefaultSelector

    def tearDown(self):
        for process, kill in self.processes:
            if process.returncode is None:
                kill()
                process.wait(timeout=RUNNER.REAP_TIMEOUT)
        self.temp.cleanup()

    @contextlib.contextmanager
    def ownership(self, *, select_fault=None, kill_fault=None, close_fault=None):
        def spawn(*args, **kwargs):
            process = self.popen(*args, **kwargs)
            kill = process.kill
            self.processes.append((process, kill))
            if kill_fault is not None:
                def failed_kill():
                    kill()
                    raise kill_fault
                process.kill = failed_kill
            return process

        def select():
            selector = self.selector()
            self.selectors.append(selector)
            if select_fault is not None:
                def raise_fault(timeout):
                    raise select_fault
                selector.select = raise_fault
            if close_fault is not None:
                close = selector.close
                def failed_close():
                    close()
                    raise close_fault
                selector.close = failed_close
            return selector

        with mock.patch.object(RUNNER.subprocess, "Popen", side_effect=spawn):
            with mock.patch.object(RUNNER.selectors, "DefaultSelector", side_effect=select):
                yield

    def produce(self, mode="done", output=0, errors=0, status=0, timeout=3):
        optimize = ["-" + "O" * sys.flags.optimize] if sys.flags.optimize else []
        return RUNNER.run(
            [sys.executable, "-B", *optimize, "-c", PRODUCER, mode,
             str(output), str(errors), str(status), str(PRODUCER_LIFETIME)],
            cwd=self.base, timeout=timeout,
            stdout_limit=STREAM_BOUND, stderr_limit=STREAM_BOUND,
        )

    def reaped(self):
        self.assertTrue(self.processes)
        for process, _ in self.processes:
            self.assertIsNotNone(process.returncode)
            with self.assertRaises(ChildProcessError):
                os.waitpid(process.pid, os.WNOHANG)
            self.assertTrue(process.stdout.closed)
            self.assertTrue(process.stderr.closed)
        for selector in self.selectors:
            self.assertIsNone(selector.get_map())

    def test_exact_bounds(self):
        with self.ownership():
            for output, errors in [(STREAM_BOUND, 0), (0, STREAM_BOUND)]:
                with self.subTest(output=output, errors=errors):
                    result = self.produce(output=output, errors=errors)
                    self.assertEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, b'O' * output)
                    self.assertEqual(result.stderr, b'E' * errors)
        self.reaped()

    def test_live_overflow(self):
        with self.ownership():
            for stream in ["stdout", "stderr"]:
                with self.subTest(stream=stream):
                    with self.assertRaisesRegex(RUNNER.OutputLimit, f"{stream} exceeds"):
                        self.produce(
                            mode="open",
                            output=STREAM_BOUND + 1 if stream == "stdout" else 0,
                            errors=STREAM_BOUND + 1 if stream == "stderr" else 0,
                        )
        self.reaped()

    def test_concurrent_streams(self):
        with self.ownership():
            result = self.produce(output=STREAM_BOUND, errors=STREAM_BOUND)
        self.assertEqual(result.stdout, b'O' * STREAM_BOUND)
        self.assertEqual(result.stderr, b'E' * STREAM_BOUND)
        self.reaped()

    def test_exit_policy(self):
        with self.ownership():
            result = self.produce(output=1, errors=1, status=7)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (7, b'O', b'E'))
        with self.assertRaises(subprocess.CalledProcessError):
            result.check_returncode()
        self.reaped()

    def test_deadline_drain_and_wait(self):
        with self.ownership():
            for mode in ["open", "closed"]:
                with self.subTest(mode=mode):
                    with self.assertRaises(subprocess.TimeoutExpired) as raised:
                        self.produce(mode=mode, timeout=DEADLINE)
                    self.assertGreater(raised.exception.timeout, 0)
                    self.assertLessEqual(raised.exception.timeout, DEADLINE)
        self.reaped()

    def test_primary_cleanup(self):
        primary, secondary = PrimaryFault("original"), CleanupFault("secondary")
        with self.ownership(select_fault=primary, kill_fault=secondary, close_fault=secondary):
            try:
                self.produce(mode="open")
            except PrimaryFault as error:
                self.assertIs(error, primary)
                self.assertIn("raise_fault", [frame.name for frame in traceback.extract_tb(error.__traceback__)])
                self.assertEqual(len(error.__notes__), 2)
            else:
                self.fail("producer scope lost its primary defect")
        self.reaped()

    def test_limit_cleanup(self):
        secondary = CleanupFault("secondary")
        with self.ownership(kill_fault=secondary, close_fault=secondary):
            with self.assertRaises(RUNNER.OutputLimit) as raised:
                self.produce(mode="open", output=STREAM_BOUND + 1)
        self.assertEqual(len(raised.exception.__notes__), 2)
        self.reaped()

    def test_success_cleanup_defect(self):
        secondary = CleanupFault("secondary")
        with self.ownership(close_fault=secondary):
            with self.assertRaises(CleanupFault) as raised:
                self.produce()
        self.assertIs(raised.exception, secondary)
        self.assertEqual(RUNNER.cleanup_notes(secondary), (
            f"Direct subprocess cleanup failed: stage=selector-close pid={self.processes[0][0].pid} class=CleanupFault",
        ))
        self.reaped()

    def test_interruption_cleanup(self):
        primary = KeyboardInterrupt("original interruption")
        with self.ownership(select_fault=primary):
            with self.assertRaises(KeyboardInterrupt) as raised:
                self.produce(mode="open")
        self.assertIs(raised.exception, primary)
        self.reaped()


if __name__ == "__main__":
    unittest.main()
