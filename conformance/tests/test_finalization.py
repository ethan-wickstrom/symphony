"""Cancellation wins restore defects after a successful direct child."""

import base64
from enum import Enum
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import time
import unittest

from symphony_conformance.driver.process import Process

PROCESS_BUDGET = 8
CHILD_BUDGET = 2
OUTPUT_LIMIT = 128 * 1024
NOTE_LIMIT = 16 * 1024
RESTORING = "restoring-after-child"
CHILD_OUTPUT = b"child-complete\n"
SIGNAL_EXIT_BASE = 128


class Consumer(Enum):
    CAPTURE = "capture"
    PROCESS = "process"


class FinalizationTest(unittest.TestCase):
    def test_capture_restore_cancel(self):
        self._restore(Consumer.CAPTURE)

    def test_process_restore_cancel(self):
        self._restore(Consumer.PROCESS)

    def _restore(self, consumer):
        script = '''
import base64
import json
import os
import signal
import sys
import time
from symphony_conformance.driver import capture
from symphony_conformance.driver.process import Custody, Process

mode, marker, budget = sys.argv[1:]
budget = float(budget)
children = []
captures = []
owner = None
real_signal = capture.signal.signal
real_popen = capture.subprocess.Popen

class ObservedCapture(capture.Capture):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        captures.append(self)

def launch(*args, **kwargs):
    if kwargs.get('start_new_session'):
        raise RuntimeError('fixture escaped outer custody')
    child = real_popen(*args, **kwargs)
    children.append((child, os.getpgid(child.pid)))
    return child

def restore(number, handler):
    current = signal.getsignal(number)
    if number == signal.SIGTERM and handler == signal.SIG_DFL and current == capture.SignalScope._collect:
        child = children[0][0]
        if child.returncode != 0 or not child.stdout.closed or not child.stderr.closed:
            raise RuntimeError('restoration began before successful child cleanup')
        print(marker, flush=True)
        os.kill(os.getpid(), signal.SIGTERM)
        raise RuntimeError('injected restore failure: ' + 'x' * (64 * 1024))
    return real_signal(number, handler)

capture.Capture = ObservedCapture
capture.subprocess.Popen = launch
capture.signal.signal = restore
argv = [sys.executable, '-I', '-c', "print('child-complete', flush=True)"]
try:
    if mode == 'capture':
        capture.run(argv, timeout=budget, stdout_limit=4096, stderr_limit=4096,
                    cwd=os.getcwd(), env=dict(os.environ))
    else:
        owner = Process(argv, cwd=os.getcwd(), env=dict(os.environ), output_limit=4096,
                        deadline=time.monotonic() + budget, custody=Custody.CHILD)
        if owner.join(budget) != 0:
            raise RuntimeError('fixture child failed')
        owner.close()
except BaseException as error:
    child, group = children[0]
    if owner is not None:
        state = owner.snapshot()
    else:
        state = {**captures[0].snapshot(), 'eof': captures[0].eof(),
                 'closed': child.stdout.closed and child.stderr.closed,
                 'reaped': child.returncode is not None}
    print(json.dumps({'type': type(error).__name__, 'code': getattr(error, 'code', None),
                      'notes': getattr(error, '__notes__', []), 'pid': child.pid,
                      'group': group, 'parent_group': os.getpgrp(), 'status': child.returncode,
                      'closed': state['closed'], 'reaped': state['reaped'], 'eof': state['eof'],
                      'stdout': base64.b64encode(state['stdout']).decode('ascii'),
                      'stderr': base64.b64encode(state['stderr']).decode('ascii')}),
          file=sys.stderr, flush=True)
    raise
finally:
    if owner is not None:
        owner.close()
'''
        flags = ["-" + "O" * min(sys.flags.optimize, 2)] if sys.flags.optimize else []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with Process([sys.executable, *flags, "-c", script, consumer.value, RESTORING, str(CHILD_BUDGET)],
                         cwd=root, env=dict(os.environ), output_limit=OUTPUT_LIMIT,
                         deadline=time.monotonic() + PROCESS_BUDGET) as command:
                status = command.join(PROCESS_BUDGET)
                captured = command.snapshot()
            diagnostic = captured["stderr"][-2048:].decode("utf-8", errors="replace")
            self.assertEqual(captured["stdout"], (RESTORING + "\n").encode(), diagnostic)
            self.assertEqual(status, SIGNAL_EXIT_BASE + signal.SIGTERM, diagnostic)
            self.assertLess(len(captured["stderr"]), NOTE_LIMIT)
            receipt = json.loads(captured["stderr"])
            self.assertEqual(receipt["type"], "SystemExit")
            self.assertEqual(receipt["code"], SIGNAL_EXIT_BASE + signal.SIGTERM)
            self.assertTrue(any("signal-restore" in note for note in receipt["notes"]))
            self.assertLess(len("\n".join(receipt["notes"])), NOTE_LIMIT)
            self.assertEqual(receipt["status"], 0)
            self.assertTrue(receipt["closed"])
            self.assertTrue(receipt["reaped"])
            self.assertEqual(receipt["group"], receipt["parent_group"])
            self.assertEqual(set(receipt["eof"]), {"stdout", "stderr"})
            self.assertEqual(base64.b64decode(receipt["stdout"], validate=True), CHILD_OUTPUT)
            self.assertEqual(base64.b64decode(receipt["stderr"], validate=True), b"")
            with self.assertRaises(ProcessLookupError):
                os.kill(receipt["pid"], 0)
