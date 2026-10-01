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
    let* default_ca_bundle =
      match Build_target.system with
      | "macosx" -> Ok "/etc/ssl/cert.pem"
      | "linux" -> Ok "/etc/ssl/certs/ca-certificates.crt"
      | target ->
          Error
            ("Unsupported compiler target: " ^ target
           ^ "; build for Linux or macOS")
    in
    Ok (cwd, env, default_ca_bundle)
  in
  let code =
    match result with
    | Error e ->
        Format.eprintf "%s; fix the host environment\n" (Text.escape e);
        2
    | Ok (cwd, env, default_ca_bundle) ->
        let runtime = Native_http.defer () in
        Eio_posix.run (fun host ->
            let clock =
              Clock_posix.create
                ~mono:(Eio.Stdenv.mono_clock host)
                ~wall:(Eio.Stdenv.clock host)
            in
            Cli.run ~fs:(Eio.Stdenv.fs host) ~net:(Eio.Stdenv.net host) ~clock
              ~runtime ~cwd ~env ~default_ca_bundle ~argv:Sys.argv
              ~out:print_string ~err:Format.err_formatter)
  in
  exit code
