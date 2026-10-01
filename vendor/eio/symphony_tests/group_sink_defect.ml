module L = Group_sink_defect_low_level
module G = L.Process.Group

exception Fixture_cancel
exception Sink_defect

let check ok message = if not ok then failwith message

let () =
  Eio_posix.run @@ fun env ->
  Eio.Switch.run @@ fun outer ->
  let cwd =
    L.openat ~sw:outer ~mode:0 L.Fs
      (Sys.getenv "SYMPHONY_GROUP_TMPDIR")
      (L.Open_flags.( + ) L.Open_flags.rdonly L.Open_flags.directory)
  in
  let null = L.openat ~sw:outer ~mode:0 L.Fs "/dev/null" L.Open_flags.rdwr in
  let reader, writer = L.pipe ~sw:outer in
  let handle, publish = Eio.Promise.create () in
  let reports = ref 0 in
  let canceled =
    match
      Eio.Switch.run (fun sw ->
          let child =
            match
              G.spawn ~sw ~cwd ~stdin:null ~stdout:writer ~stderr:writer
                ~executable:"/bin/sh"
                ~argv:[| "sh"; "-c"; "printf r; exec /bin/sleep 30" |] ~env:[||]
                ~report_cleanup:(fun _ ->
                  incr reports;
                  raise Sink_defect)
            with
            | Ok child -> child
            | Error _ -> failwith "fixture spawn failed"
          in
          Eio.Promise.resolve publish child;
          Eio_unix.Fd.close writer;
          let byte = Bytes.create 1 in
          check (L.read reader byte 0 1 = 1) "child not ready";
          raise Fixture_cancel)
    with
    | () -> false
    | exception Fixture_cancel -> true
  in
  check canceled "reporter defect replaced primary cancellation";
  let child = Eio.Promise.await handle in
  let retained () =
    match G.close child with _ -> false | exception Sink_defect -> true
  in
  check (retained () && retained ()) "reporting defect was not retained";
  check (!reports = 1) "reporting defect was retried";
  check
    (G.await_exit child = Ok (G.Signaled Sys.sigkill))
    "reporting defect skipped reap";
  let byte = Bytes.create 1 in
  check
    (Eio.Time.with_timeout_exn env#clock 2. (fun () -> L.read reader byte 0 1)
    = 0)
    "reporting defect leaked a child";
  print_endline
    "PASS: sink defect retained once; original cancellation preserved; later \
     close rethrows stored defect; native child reaped"
