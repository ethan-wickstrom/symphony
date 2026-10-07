let parse ~env config =
  match Fields.get config [ "server"; "port" ] with
  | None -> Ok None
  | Some value ->
      let result =
        Result.bind (Fields.integer env value) (fun integer ->
            Http_port.parse (Z.to_string integer))
      in
      Result.map
        (fun port -> Some port)
        (Result.map_error
           (fun message ->
             Nonempty_list.singleton
               (Fields.diagnostic ~key:"server.port" message))
           result)
