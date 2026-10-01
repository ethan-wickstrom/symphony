# Native process-custody gate

Run from the repository root:

```sh
python3 vendor/eio/symphony_tests/run.py --campaigns 3 --out /tmp/symphony-group-results
```

Both runners accept `--switch /path/to/switch`. The default is the repository's
`ocaml/` local switch. CI passes the checkout root, where `setup-ocaml` creates its
switch. Resolution is independent of the temporary build directory.

The runner builds and links this candidate's Eio, Unix and POSIX libraries against
the project switch without installing it. Each quiet campaign executes 1,000
instances of five scenarios: early leader
exit, switch release, running cancellation, startup cancellation and failed exec.
It then checks descriptor-based cwd after pathname replacement, public-close
cancellation, concurrent closes, stable cleanup errors, and signal normalization
against the actual `Unix.waitpid` result. Fixture compilation uses fatal warnings.

Fault controls prepend a narrow replacement `Unix` module to an exact copy of
`low_level.ml`; no process IDs or wait authority become production exports.
The revocation control pauses a reserved native worker before acknowledging
availability, cancels launch, then requires joined completion with zero fork and
`waitid` calls. Each admitted worker owns both observation and reap; cleanup
never allocates another native worker.
On Darwin, eight fake-sysctl cases exercise the exact production classifier.

Logs and `provenance.json` include full hashes for the process module/interface,
C stub, scheduler, thread-pool module/interface and build declarations, plus host
platform and conservative permission-error counts. Permission errors remain
results. These probes do not prove that
a successful group signal closes membership or that kernel reaping has a finite
bound. Linux behavior requires an actual Linux run.

Both runtime packages are pinned in the application. Run isolated acquisition controls
normally and with Python optimization enabled:

```sh
python3 vendor/eio/symphony_tests/thread_failure.py --out /tmp/symphony-thread-results
PYTHONOPTIMIZE=1 python3 vendor/eio/symphony_tests/thread_failure.py --out /tmp/symphony-thread-optimized
```

They force one thread-allocation failure, compare the original uncaught path,
verify typed failure/backtrace and zero fork, then reuse the same switch for a
successful child. Callback defects keep their categories. A native coordination
defect must preserve its backtrace and join revoked completion. No real resource
exhaustion is attempted.

The frozen macOS candidate passed three 5,000-case campaigns and all focused
controls. Independent admission/defect controls passed normally and optimized
against the same hashes. `../PATCHES.md` records counters, hashes, and retained
logs. Linux requires its own hosted run.
