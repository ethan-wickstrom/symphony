module L = Group_launch_failure_low_level
module G = L.Process.Group

let check ok message = if not ok then failwith message

let () =
  Eio_posix.run @@ fun _env ->
  Eio.Switch.run @@ fun outer ->
  let cwd =
    L.openat ~sw:outer ~mode:0 L.Fs
      (Sys.getenv "SYMPHONY_GROUP_TMPDIR")
      (L.Open_flags.( + ) L.Open_flags.rdonly L.Open_flags.directory)
  in
  let null = L.openat ~sw:outer ~mode:0 L.Fs "/dev/null" L.Open_flags.rdwr in
  let reports = ref [] in
  let result =
    G.spawn ~sw:outer ~cwd ~stdin:null ~stdout:null ~stderr:null
      ~executable:"/symphony-fixture-does-not-exist" ~argv:[| "missing" |]
      ~env:[||] ~report_cleanup:(fun error -> reports := error :: !reports)
  in
  let cleanup = (G.Reap Unix.ECHILD, []) in
  check
    (result = Error (G.Spawn_cleanup_failed (Unix.ENOENT, cleanup)))
    "failed exec lost its primary/cleanup error pair";
  check (!reports = [ cleanup ])
    "failed launch cleanup not reported exactly once";
  check (L.Fixture.reaps () = 1) "spawn returned before its sole real reap";
  let sink_defects = ref 0 in
  let result =
    G.spawn ~sw:outer ~cwd ~stdin:null ~stdout:null ~stderr:null
      ~executable:"/symphony-fixture-does-not-exist" ~argv:[| "missing" |]
      ~env:[||] ~report_cleanup:(fun _ ->
        incr sink_defects;
        failwith "fixture reporter defect")
  in
  check
    (result = Error (G.Spawn_cleanup_failed (Unix.ENOENT, cleanup)))
    "reporter defect replaced the primary launch failure";
  check
    (!sink_defects = 1 && L.Fixture.reaps () = 2)
    "reporter defect skipped joined cleanup";
  print_endline
    "PASS: failed exec returns primary ENOENT and cleanup ECHILD together; \
     exactly one real reap and cleanup report before return; reporter defect \
     preserves the primary pair"
