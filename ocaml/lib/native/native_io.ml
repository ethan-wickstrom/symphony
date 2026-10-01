type error = Unix of Unix.error * string | Io of Eio.Exn.err * Eio.Exn.context

let capture run =
  try Ok (run ()) with
  | Unix.Unix_error (error, operation, _) -> Error (Unix (error, operation))
  | Eio.Io (error, context) -> Error (Io (error, context))
