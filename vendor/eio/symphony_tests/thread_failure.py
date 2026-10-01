#!/usr/bin/env python3
"""Check acquisition failure and its negative control in a separate Eio build."""

import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile

FIXTURE = """module Fixture = struct
  let armed = Atomic.make false
  let arm () = Atomic.set armed true
end

"""

NEW = """    (* Resume the suspended caller if worker acquisition fails, so its cleanup
       runs. Never catch after publishing a job: it could resume twice. *)
    match Free_pool.get_thread t.free with
    | mbox -> Mailbox.put mbox (Job { fn; enqueue })
    | exception ex ->
      let bt = Printexc.get_raw_backtrace () in
      let ex = match ex with
        | Sys_error message ->
          Eio.Exn.create (Eio.Exn.Not_available (Worker_unavailable message))
        | _ -> ex
      in
      enqueue (Error (ex, bt))"""

OLD = """    let mbox = Free_pool.get_thread t.free in
    Mailbox.put mbox (Job { fn; enqueue })"""


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"instrumentation anchor changed: {old!r}")
    return text.replace(old, new, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path,
                        help="retain isolated source, binaries, and logs here")
    parser.add_argument("--switch", type=Path,
                        help="opam switch directory (default: repository/ocaml)")
    args = parser.parse_args()
    tests = Path(__file__).resolve().parent
    vendor = tests.parent
    project = vendor.parent.parent
    switch = (args.switch or project / "ocaml").resolve()
    out = (args.out or Path(tempfile.mkdtemp(prefix="symphony-thread-failure-"))).resolve()
    out.mkdir(parents=True, exist_ok=True)
    source_root = out / "eio"
    shutil.copytree(vendor, source_root,
                    ignore=shutil.ignore_patterns("_build", ".git", "*.install"))
    source_file = source_root / "lib_eio/unix/thread_pool.ml"
    original = source_file.read_text()
    print(f"thread_pool_sha256={hashlib.sha256(original.encode()).hexdigest()}", flush=True)
    injected = FIXTURE + replace_once(original, "  let make_thread t =\n",
        "  let make_thread t =\n"
        "    if Atomic.exchange Fixture.armed false then\n"
        "      raise (Sys_error \"Thread.create: Resource temporarily unavailable (fixture)\");\n")
    interface = source_root / "lib_eio/unix/thread_pool.mli"
    interface.write_text(interface.read_text() +
                         "\nmodule Fixture : sig val arm : unit -> unit end\n")
    low_level = source_root / "lib_eio_posix/low_level.ml"
    anchor = ('  external eio_spawn : Unix.file_descr -> '
              'Eio_unix.Private.Fork_action.c_action list -> int = "caml_eio_posix_spawn"')
    replacement = anchor.replace("external eio_spawn", "external raw_eio_spawn") + (
        "\n  let eio_spawn fd actions =\n"
        "    Atomic.incr Fixture.fork_count;\n"
        "    raw_eio_spawn fd actions")
    low_level.write_text(
        "module Fixture = struct\n"
        "  exception Native_condition_defect\n"
        "  let fork_count = Atomic.make 0\n"
        "  let forks () = Atomic.get fork_count\n"
        "  let assignment_enabled = Atomic.make false\n"
        "  let assignment_armed = Atomic.make false\n"
        "  let assignments = Atomic.make 0\n"
        "  let assigned, set_assigned = Eio.Promise.create ()\n"
        "  let arm_assignment () =\n"
        "    Atomic.set assignment_enabled true; Atomic.set assignment_armed true\n"
        "  let completed_assignments () = Atomic.get assignments\n"
        "  let condition_wait condition mutex =\n"
        "    if Atomic.exchange assignment_armed false then raise Native_condition_defect;\n"
        "    Condition.wait condition mutex\n"
        "  let assignment_done () =\n"
        "    if Atomic.get assignment_enabled then (\n"
        "      Atomic.incr assignments; Eio.Promise.resolve set_assigned ())\n"
        "  let before_launch () =\n"
        "    if Atomic.get assignment_enabled then (\n"
        "      Eio.Promise.await assigned; Eio.Fiber.await_cancel ())\n"
        "end\n\n" + replace_once(low_level.read_text(), anchor, replacement))
    instrumented = replace_once(low_level.read_text(),
        "              Condition.wait t.changed t.lock;\n              assigned ()",
        "              Fixture.condition_wait t.changed t.lock;\n              assigned ()")
    instrumented = replace_once(instrumented,
        "with_lock t (fun () -> publish t.completed t.set_completed result);",
        "with_lock t (fun () -> Fixture.assignment_done (); publish t.completed t.set_completed result);")
    instrumented = replace_once(instrumented,
        "let launch t errors_w c_actions =\n", "let launch t errors_w c_actions =\n      Fixture.before_launch ();\n")
    low_level.write_text(instrumented)
    low_interface = source_root / "lib_eio_posix/low_level.mli"
    low_interface.write_text(low_interface.read_text() +
        "\nmodule Fixture : sig\n exception Native_condition_defect\n"
        " val forks : unit -> int\n val arm_assignment : unit -> unit\n"
        " val completed_assignments : unit -> int\nend\n")
    controls = ("thread_failure", "thread_admission", "thread_defects", "thread_assignment")
    for name in controls:
        control = source_root / (name + "_control")
        control.mkdir()
        (control / "dune").write_text(
            "(executable\n (name main)\n (libraries eio eio_posix))\n")
        for suffix in (".ml", ".mli"):
            shutil.copyfile(tests / (name + suffix), control / ("main" + suffix))
    build = ["opam", "exec", "--switch", str(switch), "--", "dune", "build",
             "--root", str(source_root), "--only-packages", "eio,eio_posix",
             "thread_failure_control/main.exe"]
    executable = source_root / "_build/default/thread_failure_control/main.exe"
    for name, source in (("positive", injected),
                         ("negative", replace_once(injected, NEW, OLD))):
        source_file.write_text(source)
        with (out / (name + "-build.log")).open("w") as log:
            subprocess.run(build, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=180)
        result = subprocess.run([str(executable)], text=True, capture_output=True,
                                check=False, timeout=15)
        (out / (name + ".log")).write_text(result.stdout + result.stderr)
        expected = ("original_error=true original_backtrace=true io_error=true caller_finalizer=true switch_release=true\n"
                    if name == "positive" else
                    "original_error=true original_backtrace=true io_error=false caller_finalizer=false switch_release=false\n")
        if result.stdout != expected or result.returncode != (0 if name == "positive" else 1):
            raise RuntimeError(f"{name} result changed: {result.returncode}: {result.stdout!r} {result.stderr!r}")
        print(f"PASS {name}: {result.stdout.strip()}", flush=True)
    source_file.write_text(injected)
    for name in controls[1:]:
        target = name + "_control/main.exe"
        with (out / (name + "-build.log")).open("w") as log:
            subprocess.run(build[:-1] + [target], stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=180)
        argv = [str(source_root / "_build/default" / target)]
        if name in ("thread_admission", "thread_assignment"):
            argv.append(str(out))
        result = subprocess.run(argv,
                                text=True, capture_output=True, check=False, timeout=15)
        (out / (name + ".log")).write_text(result.stdout + result.stderr)
        if result.returncode != 0 or not result.stdout.startswith("PASS "):
            raise RuntimeError(f"{name} failed: {result.returncode}: {result.stdout!r} {result.stderr!r}")
        print(result.stdout.strip(), flush=True)
    print(f"PASS thread-acquisition failure gate; results={out}", flush=True)


if __name__ == "__main__":
    main()
