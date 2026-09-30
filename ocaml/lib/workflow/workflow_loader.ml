type error =
  | Missing_file of Diagnostic.t
  | Read_error of Diagnostic.t
  | Invalid_document of Workflow_document.error

module type IO = sig
  type t

  val read : t -> file:Workflow_path.t -> (string, error) result
end

module type S = sig
  type io

  val load : io -> file:Workflow_path.t -> (Workflow_document.t, error) result
end

module Make (IO : IO) = struct
  type io = IO.t

  let load io ~file =
    match IO.read io ~file with
    | Error _ as e -> e
    | Ok text ->
        Result.map_error
          (fun e -> Invalid_document e)
          (Workflow_document.parse ~file text)
end
