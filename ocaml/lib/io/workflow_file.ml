type t = Eio.Fs.dir_ty Eio.Path.t

let make t = t
let max_bytes = 1_048_576

let diagnostic file message remedy =
  Diagnostic.make
    ~site:
      (Diagnostic.Workflow
         { file = Workflow_path.display file; key = None; line = None })
    ~message ~remedy

let read fs ~file =
  let path = Eio.Path.( / ) fs (Workflow_path.display file) in
  try
    Eio.Path.with_open_in path (fun input ->
        match
          Eio.Buf_read.parse ~max_size:(max_bytes + 1) Eio.Buf_read.take_all
            input
        with
        | Ok text when String.length text <= max_bytes -> Ok text
        | Ok _ | Error (`Msg _) ->
            Error
              (Workflow_loader.Read_error
                 (diagnostic file "workflow exceeds the 1 MiB input limit"
                    "shorten the workflow file")))
  with
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
      Error
        (Workflow_loader.Missing_file
           (diagnostic file "workflow file is missing"
              "create this file or pass the correct workflow path"))
  | Eio.Io _ ->
      Error
        (Workflow_loader.Read_error
           (diagnostic file "cannot read workflow file"
              "check file type, permissions and filesystem availability"))
