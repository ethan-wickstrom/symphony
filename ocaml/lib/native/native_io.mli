type error = Unix of Unix.error * string | Io of Eio.Exn.err * Eio.Exn.context

val capture : (unit -> 'a) -> ('a, error) result
(** Execute the thunk once at the native syscall boundary.
    [capture (fun () -> x) = Ok x]. Unix failures retain their error and
    operation but discard their path; typed Eio IO failures retain their payload
    and context. Consumers decide how to redact these private values. Every
    other exception, including a worker-function [Sys_error], propagates with
    its physical identity and original backtrace. Only worker admission may
    classify its own failure as typed Eio IO. User callbacks never enter this
    classifier. *)
