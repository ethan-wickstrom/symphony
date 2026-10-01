module L = Group_revoked_low_level
module G = L.Process.Group

exception Fixture_cancel

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
  let ready, publish = Eio.Promise.create () in
  let canceled, () =
    Eio.Fiber.pair
      (fun () ->
        match
          Eio.Switch.run (fun sw ->
              Eio.Promise.resolve publish sw;
              ignore
                (G.spawn ~sw ~cwd ~stdin:null ~stdout:null ~stderr:null
                   ~executable:"/bin/sleep" ~argv:[| "sleep"; "30" |] ~env:[||]
                   ~report_cleanup:(fun _ ->
                     failwith "cleanup failed without child")))
        with
        | () -> false
        | exception Fixture_cancel -> true)
      (fun () ->
        let sw = Eio.Promise.await ready in
        Eio.Promise.await L.Fixture.entered;
        Eio.Switch.fail sw Fixture_cancel;
        L.Fixture.allow ())
  in
  check canceled "reservation cancellation changed outcome";
  check (L.Fixture.fork_calls () = 0) "revoked reservation forked";
  check (L.Fixture.wait_calls () = 0) "revoked reservation invoked waitid";
  print_endline
    "PASS: pre-fork reservation cancellation joins the admitted worker; zero \
     fork and observation syscalls"
