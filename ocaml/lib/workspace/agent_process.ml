module type S = sig
  module Path : Workspace_path.S

  type t
  type process
  type error = Diagnostic.t
  type exit = Exited of int | Signaled of int

  val with_process :
    t ->
    cwd:Path.t ->
    env:Environment.child ->
    command:string ->
    (process -> ('a, error) result) ->
    ('a, error) result

  val read : process -> (string option, error) result
  val write : process -> string -> (unit, error) result
  val stderr : process -> (string option, error) result
  val await_exit : process -> (exit, error) result
end
