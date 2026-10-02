let rec leaves (error, backtrace) =
  match error with
  | Eio.Exn.Multiple values -> List.concat_map leaves (List.rev values)
  | Eio.Io (Eio.Exn.Multiple_io values, _) ->
      List.concat_map
        (fun (error, context, trace) -> leaves (Eio.Io (error, context), trace))
        values
  | _ -> [ (error, backtrace) ]
