let () =
  (* Ambient process inputs are captured only at this composition boundary. *)
  let bindings =
    Array.to_list (Unix.environment ())
    |> List.filter_map (fun s ->
        match String.index_opt s '=' with
        | None -> None
        | Some i ->
            Some
              (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1)))
  in
  let result =
    let ( let* ) = Result.bind in
    let* cwd = Absolute_path.parse (Sys.getcwd ()) in
    let temp =
      Option.value ~default:"/tmp" (List.assoc_opt "TMPDIR" bindings)
    in
    let* temp_dir = Absolute_path.parse temp in
    let* env = Environment.of_bindings ~temp_dir bindings in
    Ok (cwd, env)
  in
  let code =
    match result with
    | Error e ->
        Format.eprintf "%s; fix the host environment\n" (Text.escape e);
        2
    | Ok (cwd, env) ->
        Eio_posix.run (fun host ->
            Cli.run ~fs:(Eio.Stdenv.fs host) ~cwd ~env ~argv:Sys.argv
              ~out:print_string ~err:Format.err_formatter)
  in
  exit code
