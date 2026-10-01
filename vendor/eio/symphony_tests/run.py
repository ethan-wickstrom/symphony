#!/usr/bin/env python3
"""Build and exercise the exact candidate without installing it into opam."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile


PERMISSION = """module Unix = struct
  include Unix
  let kill pid signal =
    if pid < 0 then raise (Unix_error (EPERM, "kill", "fixture"))
    else kill pid signal
end
"""

FAILURES = """module Unix = struct
  include Unix
  let kill pid signal =
    if pid >= 0 then kill pid signal;
    raise (Unix_error (EPERM, "kill", "fixture"))
  let waitpid flags pid =
    ignore (waitpid flags pid);
    raise (Unix_error (ECHILD, "waitpid", "fixture"))
end
"""

SIGNALS = """module Fixture = struct
  let last = ref None
  let take () = let value = !last in last := None; value
end
module Unix = struct
  include Unix
  let waitpid flags pid =
    let result = waitpid flags pid in
    Fixture.last := Some (snd result);
    result
end
"""

LAUNCH_FAILURE = """module Fixture = struct
  let count = Atomic.make 0
  let reaps () = Atomic.get count
end
module Unix = struct
  include Unix
  let waitpid flags pid =
    ignore (waitpid flags pid);
    Atomic.incr Fixture.count;
    raise (Unix_error (ECHILD, "waitpid", "fixture"))
end
"""

REVOKED = """module Fixture = struct
  let entered, announce = Eio.Promise.create ()
  let mutex = Mutex.create ()
  let condition = Condition.create ()
  let released = ref false
  let calls = Atomic.make 0
  let forks = Atomic.make 0
  let before () =
    Eio.Promise.resolve announce ();
    Mutex.lock mutex;
    while not !released do Condition.wait condition mutex done;
    Mutex.unlock mutex
  let allow () =
    Mutex.lock mutex;
    released := true;
    Condition.broadcast condition;
    Mutex.unlock mutex
  let wait_calls () = Atomic.get calls
  let count_wait () = Atomic.incr calls
  let fork_calls () = Atomic.get forks
  let count_fork () = Atomic.incr forks
end
"""


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"instrumentation anchor changed: {old!r}")
    return text.replace(old, new, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--campaigns", type=int, default=3,
                        help="quiet campaigns, each with 5,000 scenarios (default: 3)")
    parser.add_argument("--out", type=Path,
                        help="retain binaries and per-probe logs in this directory")
    parser.add_argument("--switch", type=Path,
                        help="opam switch directory (default: repository/ocaml)")
    args = parser.parse_args()
    if args.campaigns < 0:
        parser.error("--campaigns must be nonnegative")
    tests = Path(__file__).resolve().parent
    vendor = tests.parent
    root = vendor.parent.parent
    switch = (args.switch or root / "ocaml").resolve()
    out = (args.out or Path(tempfile.mkdtemp(prefix="symphony-group-"))).resolve()
    out.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ, SYMPHONY_GROUP_TMPDIR=str(out))
    opam = ["opam", "exec", "--switch", str(switch), "--"]
    build = vendor / "_build/default/lib_eio_posix"
    compiler = opam + ["ocamlopt", "-thread", "-open", "Eio_posix__"]
    local_objects = [(vendor / "_build/default" / directory / ("." + name + ".objs") / kind)
                     for directory, name in [
                         ("lib_eio", "eio"), ("lib_eio/core", "eio__core"),
                         ("lib_eio/utils", "eio_utils"), ("lib_eio/unix", "eio_unix"),
                         ("lib_eio/runtime_events", "eio_runtime_events")]
                     for kind in ["byte", "native"]]
    for path in local_objects + [build / ".eio_posix.objs/byte", build / ".eio_posix.objs/native", build, out]:
        compiler += ["-I", str(path)]

    def command(argv, name, timeout=180):
        log = out / (name + ".log")
        try:
            with log.open("w") as stream:
                subprocess.run(argv, cwd=out, env=environment, stdout=stream,
                               stderr=subprocess.STDOUT, check=True, timeout=timeout)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            parser.exit(1, f"FAIL {name}: {log}\n{log.read_text()}")
        lines = log.read_text().strip().splitlines()
        detail = lines[-1] if lines and not name.startswith(("compile", "instrument")) else ""
        print(f"PASS {name}: {detail}", flush=True)

    command(opam + ["dune", "build", "--root", str(vendor), "--only-packages",
                    "eio,eio_posix", "lib_eio_posix/eio_posix.cmxa",
                    "lib_eio/unix/eio_unix.cmxa", "lib_eio/eio.cmxa",
                    "lib_eio/core/eio__core.cmxa", "lib_eio/utils/eio_utils.cmxa",
                    "lib_eio/runtime_events/eio_runtime_events.cmxa",
                    "lib_eio/unix/libeio_unix_stubs.a", "lib_eio_posix/libeio_posix_stubs.a"], "build")
    archives = subprocess.check_output(opam + ["ocamlfind", "query", "-recursive",
                    "-predicates", "native", "-format", "%p|%+A",
                    "eio,eio.utils,eio.unix,fmt,iomux"], text=True)
    local = {"eio": "lib_eio/eio", "eio.core": "lib_eio/core/eio__core",
             "eio.unix": "lib_eio/unix/eio_unix", "eio.utils": "lib_eio/utils/eio_utils",
             "eio.runtime_events": "lib_eio/runtime_events/eio_runtime_events"}
    for line in archives.splitlines():
        package, paths = line.split("|", 1)
        if package in local:
            path = vendor / "_build/default" / (local[package] + ".cmxa")
            compiler += ["-I", str(path.parent), "-cclib", "-L" + str(path.parent), str(path)]
        else:
            for path in paths.split():
                compiler += ["-I", str(Path(path).parent), "-cclib", "-L" + str(Path(path).parent), path]
    compiler += ["-cclib", "-L" + str(build), str(build / "eio_posix.cmxa")]
    source = (vendor / "lib_eio_posix/low_level.ml").read_text()
    interface = (vendor / "lib_eio_posix/low_level.mli").read_text()
    paths = ["lib_eio_posix/low_level.ml", "lib_eio_posix/low_level.mli",
             "lib_eio_posix/eio_group_stubs.c", "lib_eio_posix/sched.ml",
             "lib_eio_posix/sched.mli", "lib_eio_posix/dune", "lib_eio_posix/primitives.h",
             "lib_eio/unix/thread_pool.ml", "lib_eio/unix/thread_pool.mli"]
    hashes = {path: hashlib.sha256((vendor / path).read_bytes()).hexdigest() for path in paths}
    manifest = {"host": platform.platform(), "sha256": hashes, "opam_switch": str(switch),
                "ocaml": subprocess.check_output(opam + ["ocamlc", "-version"], text=True).strip()}
    (out / "provenance.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    for path, digest in hashes.items():
        print(f"source_sha256[{path}]={digest}", flush=True)
    print(f"candidate_sha256={hashlib.sha256(source.encode()).hexdigest()} host={platform.platform()}", flush=True)
    extras = {
        "permission": (PERMISSION, ""),
        "sink_defect": (PERMISSION, ""),
        "failures": (FAILURES, ""),
        "signals": (SIGNALS, "module Fixture : sig val take : unit -> Unix.process_status option end\n"),
        "launch_failure": (LAUNCH_FAILURE, "module Fixture : sig val reaps : unit -> int end\n"),
        "revoked": (REVOKED, "module Fixture : sig val entered : unit Eio.Promise.t val allow : unit -> unit val wait_calls : unit -> int val fork_calls : unit -> int end\n"),
    }
    for name in ["host", "close", "permission", "failures", "signals", "revoked", "launch_failure", "sink_defect"]:
        for suffix in [".ml", ".mli"]:
            shutil.copyfile(tests / ("group_" + name + suffix), out / ("group_" + name + suffix))
        inputs = []
        if name in extras:
            prefix, signature = extras[name]
            instrumented = source
            if name == "revoked":
                instrumented = replace_once(instrumented,
                    'external wait_exit : int -> exit = "caml_eio_posix_wait_exit"',
                    'external raw_wait_exit : int -> exit = "caml_eio_posix_wait_exit"\n    let wait_exit pid = Fixture.count_wait (); raw_wait_exit pid')
                instrumented = replace_once(instrumented,
                    "let produce t =\n      with_lock", "let produce t =\n      Fixture.before ();\n      with_lock")
                instrumented = replace_once(instrumented,
                    'external eio_spawn : Unix.file_descr -> Eio_unix.Private.Fork_action.c_action list -> int = "caml_eio_posix_spawn"',
                    'external raw_spawn : Unix.file_descr -> Eio_unix.Private.Fork_action.c_action list -> int = "caml_eio_posix_spawn"\n  let eio_spawn fd actions = Fixture.count_fork (); raw_spawn fd actions')
            module = "group_" + ("signal" if name == "signals" else name) + "_low_level"
            (out / (module + ".ml")).write_text(prefix + instrumented)
            (out / (module + ".mli")).write_text(interface + "\n" + signature)
            module_sources = [str(out / (module + suffix)) for suffix in [".mli", ".ml"]]
            command(compiler + ["-c"] + module_sources, "instrument-" + name)
            inputs.append(str(out / (module + ".cmx")))
        inputs += [str(out / ("group_" + name + suffix)) for suffix in [".mli", ".ml"]]
        command(compiler + ["-w", "+a-42", "-warn-error", "+a"] + inputs +
                ["-o", str(out / name)], "compile-" + name)
    for campaign in range(1, args.campaigns + 1):
        command([str(out / "host")], f"quiet-{campaign}")
    for name in ["close", "permission", "failures", "signals", "revoked", "launch_failure", "sink_defect"]:
        command([str(out / name)], name)
    if platform.system() == "Darwin":
        for suffix in [".ml", ".mli", "_stubs.c"]:
            shutil.copyfile(tests / ("group_controls" + suffix), out / ("group_controls" + suffix))
        include = vendor / "lib_eio_posix"
        command(compiler + ["-ccopt", "-Wall -Wextra -Werror", "-ccopt", "-I" + str(include),
                           str(out / "group_controls_stubs.c"), str(out / "group_controls.mli"),
                           str(out / "group_controls.ml"), "-o", str(out / "controls")], "compile-controls")
        command([str(out / "controls")], "controls")
    print(f"PASS native custody gate; results={out}", flush=True)


if __name__ == "__main__":
    main()
