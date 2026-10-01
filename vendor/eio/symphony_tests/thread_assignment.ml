module L = Eio_posix.Low_level
module G = L.Process.Group

let require condition detail = if not condition then failwith detail

let () =
  let directory =
    match Array.to_list Sys.argv with
    | [ _; directory ] -> directory
    | _ -> failwith "supply the runner's fixture directory"
  in
  let cwd_unix = Unix.openfile directory [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  let null_unix = Unix.openfile "/dev/null" [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
  let preserved =
    Fun.protect
      ~finally:(fun () ->
        Unix.close cwd_unix;
        Unix.close null_unix)
      (fun () ->
        match
          Eio_posix.run (fun _ ->
              Eio.Switch.run (fun sw ->
                  let cwd =
                    Eio_unix.Fd.of_unix ~sw ~close_unix:false cwd_unix
                  in
                  let null =
                    Eio_unix.Fd.of_unix ~sw ~close_unix:false null_unix
                  in
                  L.Fixture.arm_assignment ();
                  ignore
                    (G.spawn ~sw ~cwd ~stdin:null ~stdout:null ~stderr:null
                       ~executable:"/bin/sh" ~argv:[| "sh"; "-c"; "exit 0" |]
                       ~env:[||] ~report_cleanup:(fun _ -> ()))))
        with
        | () -> false
        | exception L.Fixture.Native_condition_defect -> true)
  in
  require preserved "native assignment defect was lost or replaced";
  require (L.Fixture.forks () = 0) "revoked assignment forked a child";
  require
    (L.Fixture.completed_assignments () = 1)
    "native completion was orphaned";
  print_endline
    "PASS assignment defect: original defect preserved; zero fork; revoked \
     native completion joined"
