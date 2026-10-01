type status = Acquired | Busy

external try_lock : Unix.file_descr -> bool = "symphony_workspace_flock"

let acquire fd =
  Eio_unix.run_in_systhread ~label:"workspace-flock" (fun () ->
      Eio_unix.Fd.use_exn "workspace-flock" fd (fun raw ->
          try Ok (if try_lock raw then Acquired else Busy)
          with Unix.Unix_error (error, _, _) -> Error error))
