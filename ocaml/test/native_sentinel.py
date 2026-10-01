"""Keep one live member in the watchdog's group until its final SIGKILL."""

import os
import signal
import sys


def main():
    if len(sys.argv) != 2:
        raise SystemExit("native sentinel requires one executable path")

    # Inherit ignored signals at fork, before the child can be scheduled.
    previous = {
        signum: signal.signal(signum, signal.SIG_IGN)
        for signum in (signal.SIGINT, signal.SIGTERM)
    }
    if os.fork() == 0:
        while True:
            signal.pause()

    for signum, handler in previous.items():
        signal.signal(signum, handler)

    # Match Popen's restore_signals after Python's startup dispositions.
    for name in ("SIGPIPE", "SIGXFZ", "SIGXFSZ"):
        signum = getattr(signal, name, None)
        if signum is not None:
            signal.signal(signum, signal.SIG_DFL)

    binary = sys.argv[1]
    os.execv(binary, [binary, "--color=never"])


if __name__ == "__main__":
    main()
