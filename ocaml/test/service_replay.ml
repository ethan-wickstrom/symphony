let () =
  let seed = ref None in
  let prefix = ref None in
  let options =
    [
      ("--seed", Arg.Int (fun value -> seed := Some value), "N Script seed");
      ("--prefix", Arg.Int (fun value -> prefix := Some value), "N Causal gates");
    ]
  in
  Arg.parse options
    (fun _ ->
      raise (Arg.Bad "Use --seed and --prefix; no positional arguments."))
    "Replay one service scenario, including its joined shutdown tail.";
  let result =
    match (!seed, !prefix) with
    | Some seed, Some prefix ->
        Service_test_support.Service_sim_test.replay ~seed ~prefix
    | None, _ | _, None -> Error "Both --seed and --prefix are required."
  in
  match result with
  | Ok () -> print_endline "Service replay passed."
  | Error message ->
      prerr_endline message;
      exit 2
