"""Exec a candidate after an acknowledged same-UID process-group guard."""

import os
import signal
import sys

GUARD_READY = b"guard-ready"
GUARD_PREFIX = b"guard "


def main():
    if len(sys.argv) < 3:
        raise SystemExit("group sentinel requires an admission fd and candidate argv")
    admission = int(sys.argv[1])
    argv = sys.argv[2:]
    previous = {number: signal.signal(number, signal.SIG_IGN)
                for number in (signal.SIGINT, signal.SIGTERM)}
    reader, writer = os.pipe()
    guard = os.fork()
    if guard == 0:
        try:
            os.close(reader)
            os.close(admission)
            for fd in (0, 1, 2):
                os.close(fd)
            os.write(writer, GUARD_READY)
            os.close(writer)
            while True:
                signal.pause()
        except BaseException:
            os._exit(1)

    os.close(writer)
    try:
        if os.read(reader, len(GUARD_READY)) != GUARD_READY:
            raise RuntimeError("process-group guard failed before candidate exec")
    finally:
        os.close(reader)
    receipt = GUARD_PREFIX + str(guard).encode("ascii") + b"\n"
    try:
        if os.write(admission, receipt) != len(receipt):
            raise RuntimeError("process-group admission receipt was incomplete")
    finally:
        os.close(admission)

    for number, handler in previous.items():
        signal.signal(number, handler)
    for name in ("SIGPIPE", "SIGXFZ", "SIGXFSZ"):
        number = getattr(signal, name, None)
        if number is not None:
            signal.signal(number, signal.SIG_DFL)
    os.execvpe(argv[0], argv, os.environ)


if __name__ == "__main__":
    main()
