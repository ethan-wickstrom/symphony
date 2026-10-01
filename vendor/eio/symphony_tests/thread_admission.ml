module L = Eio_posix.Low_level
module G = L.Process.Group

let message = "Thread.create: Resource temporarily unavailable (fixture)"
let require condition detail = if not condition then failwith detail

let () =
  let directory =
    match Array.to_list Sys.argv with
    | [ _; directory ] -> directory
    | _ -> failwith "supply the runner's fixture directory"
  in
  let cwd_unix = Unix.openfile directory [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  let null_unix = Unix.openfile "/dev/null" [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
  Fun.protect
    ~finally:(fun () ->
      Unix.close cwd_unix;
      Unix.close null_unix)
    (fun () ->
      Eio_posix.run (fun _ ->
          Eio.Switch.run (fun sw ->
              let cwd = Eio_unix.Fd.of_unix ~sw ~close_unix:false cwd_unix in
              let null = Eio_unix.Fd.of_unix ~sw ~close_unix:false null_unix in
              let reports = ref 0 in
              let spawn () =
                G.spawn ~sw ~cwd ~stdin:null ~stdout:null ~stderr:null
                  ~executable:"/bin/sh" ~argv:[| "sh"; "-c"; "exit 0" |]
                  ~env:[||] ~report_cleanup:(fun _ -> incr reports)
              in
              Eio_unix.Private.Thread_pool.Fixture.arm ();
              let rejected =
                match spawn () with
                | Error (G.Worker_unavailable error) ->
                    String.equal error message
                | Error (G.Spawn_error _ | G.Spawn_cleanup_failed _) | Ok _ ->
                    false
              in
              require rejected "native worker failure lost its checked result";
              require (L.Fixture.forks () = 0) "failed admission forked a child";
              require (!reports = 0)
                "failed admission reported nonexistent cleanup failure";
              let child =
                match spawn () with
                | Ok child -> child
                | Error (G.Worker_unavailable error) ->
                    failwith ("subsequent worker admission: " ^ error)
                | Error (G.Spawn_error error | G.Spawn_cleanup_failed (error, _))
                  ->
                    failwith ("subsequent spawn: " ^ Unix.error_message error)
              in
              require
                (G.await_exit child = Ok (G.Exited 0))
                "subsequent child failed";
              require (G.close child = Ok ()) "subsequent cleanup failed";
              require
                (L.Fixture.forks () = 1)
                "unexpected fork count after retry";
              require (!reports = 0)
                "successful cleanup unexpectedly reported an error")));
  print_endline
    "PASS admission: original host diagnostic retained; zero fork on \
     rejection; same outer switch dispatches and reaps next child"
