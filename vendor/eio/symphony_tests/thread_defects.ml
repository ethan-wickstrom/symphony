let require condition detail = if not condition then failwith detail

let check failure =
  let observed =
    match Eio_unix.run_in_systhread (fun () -> raise failure) with
    | (_ : unit) -> None
    | exception ex -> Some ex
  in
  require (observed = Some failure) "worker failure was reclassified or lost"

let () =
  Eio_posix.run (fun _ ->
      Eio.Switch.run (fun _ ->
          List.iter check
            [
              Sys_error "worker function fixture";
              Out_of_memory;
              Invalid_argument "worker function fixture";
            ]));
  print_endline
    "PASS worker defects: Sys_error, Out_of_memory, and Invalid_argument \
     remain unchanged"
