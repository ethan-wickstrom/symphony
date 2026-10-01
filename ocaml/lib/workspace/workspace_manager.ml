type error =
  | Invalid_key of Diagnostic.t
  | Unsafe_path of Diagnostic.t
  | Ownership_conflict of Diagnostic.t
  | Filesystem_error of Diagnostic.t
  | Hook_failed of Diagnostic.t
  | Hook_timeout of Diagnostic.t

module type PURE = sig
  module Path : Workspace_path.S

  type reference

  val reference :
    settings:Workspace_settings.t ->
    env:Environment.child ->
    scope:Tracker_scope.t ->
    issue_id:Issue_id.t ->
    identifier:Issue_identifier.t ->
    (reference, error) result

  val identifier : reference -> Issue_identifier.t
  val issue_id : reference -> Issue_id.t
  val scope : reference -> Tracker_scope.t
  val environment : reference -> Environment.child
  val key : reference -> Workspace_key.t
  val settings : reference -> Workspace_settings.t

  type cleanup = { request_id : Request_id.t; workspace : reference }
end

module type DRIVER = sig
  module Contract : PURE

  type t
  type lease
  type origin = Created | Reused

  val with_lease :
    t -> Contract.reference -> (origin -> lease -> 'a) -> ('a, error) result

  val with_existing :
    t -> Contract.reference -> (lease option -> 'a) -> ('a, error) result

  val path : lease -> (Contract.Path.t, error) result
  val hook : t -> lease -> Workspace_settings.hook -> (unit, error) result
  val remove : t -> lease -> (unit, error) result
  val cleanup_scope : t -> (unit -> 'a) -> 'a
  val report : t -> error -> unit
end

module type S = sig
  module Contract : PURE

  type t

  val with_workspace :
    t ->
    Contract.reference ->
    (Contract.Path.t -> ('a, error) result) ->
    ('a, error) result

  val cleanup : t -> Contract.cleanup -> (unit, error) result
  val inspect : t -> Contract.reference -> (string option, error) result
end

module Make (Driver : DRIVER) = struct
  module Contract = Driver.Contract

  type t = Driver.t
  type 'a outcome = Returned of 'a | Raised of exn * Printexc.raw_backtrace

  let capture run =
    match run () with
    | value -> Returned value
    | exception exn -> Raised (exn, Printexc.get_raw_backtrace ())

  let resume = function
    | Returned value -> value
    | Raised (exn, trace) -> Printexc.raise_with_backtrace exn trace

  let first_fault first second =
    match first with
    | Raised _ -> first
    | Returned () -> second

  let resolve primary cleanup =
    match primary with
    | Returned (Error _ as error) -> error
    | Returned (Ok value) ->
        resume cleanup;
        Ok value
    | Raised (exn, trace) -> Printexc.raise_with_backtrace exn trace

  let observe t = function
    | Ok () -> ()
    | Error error -> Driver.report t error

  let hook t lease phase = observe t (Driver.hook t lease phase)

  let remove t lease =
    let before =
      capture (fun () -> hook t lease Workspace_settings.Before_remove)
    in
    let removal = capture (fun () -> Driver.remove t lease) in
    resolve removal before

  let rollback t origin lease =
    match origin with
    | Driver.Reused -> ()
    | Driver.Created -> observe t (remove t lease)

  let finish t lease cleanup =
    capture (fun () ->
        Driver.cleanup_scope t (fun () ->
            let after =
              capture (fun () -> hook t lease Workspace_settings.After_run)
            in
            let completed = capture cleanup in
            resume (first_fault after completed)))

  let prepare t origin lease =
    let created =
      match origin with
      | Driver.Reused -> Ok ()
      | Driver.Created -> Driver.hook t lease Workspace_settings.After_create
    in
    Result.bind created (fun () ->
        Result.bind (Driver.hook t lease Workspace_settings.Before_run)
          (fun () -> Driver.path lease))

  let attempt t origin lease run =
    (* Capture the primary outcome before finalizers: a cleanup defect cannot
       replace it or skip a later rollback/removal obligation. *)
    match capture (fun () -> prepare t origin lease) with
    | Returned (Ok path) ->
        let primary = capture (fun () -> run path) in
        let cleanup = finish t lease (fun () -> ()) in
        resolve primary cleanup
    | Returned (Error error) ->
        let cleanup = finish t lease (fun () -> rollback t origin lease) in
        resolve (Returned (Error error)) cleanup
    | Raised (exn, trace) ->
        let cleanup = finish t lease (fun () -> rollback t origin lease) in
        resolve (Raised (exn, trace)) cleanup

  let with_workspace t reference run =
    match
      Driver.with_lease t reference (fun origin lease ->
          attempt t origin lease run)
    with
    | Ok result -> result
    | Error error -> Error error

  let cleanup t request =
    match
      Driver.with_existing t request.Contract.workspace (function
        | None -> Ok ()
        | Some lease -> Driver.cleanup_scope t (fun () -> remove t lease))
    with
    | Ok result -> result
    | Error error -> Error error

  let inspect t reference =
    match
      Driver.with_existing t reference (function
        | None -> Ok None
        | Some lease ->
            Result.map
              (fun path -> Some (Contract.Path.display path))
              (Driver.path lease))
    with
    | Ok result -> result
    | Error error -> Error error
end
