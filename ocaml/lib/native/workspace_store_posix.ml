module Contract = Workspace_contract_posix
module Directory = Workspace_directory

type t = {
  fs : Eio.Fs.dir_ty Eio.Path.t;
  report : Workspace_manager.error -> unit;
  close_path : Workspace_path_posix.t -> unit;
}

type origin = Created | Reused

type phase =
  | Active of Workspace_path_posix.t
  | Retired of (unit, Workspace_manager.error) result Native_outcome.t

type lease = {
  reference : Contract.reference;
  guard : Directory.key_guard;
  directory : Directory.directory;
  owner : Workspace_owner.t;
  mutable phase : phase;
}

type 'a completion = Pending | Finished of 'a Native_outcome.t

let ( let* ) = Result.bind
let create ~fs ~report ~close_path = { fs; report; close_path }
let reference lease = lease.reference

let diagnostic reference message remedy =
  Diagnostic.make
    ~site:
      (Diagnostic.Issue
         {
           id = Contract.issue_id reference;
           identifier = Contract.identifier reference;
         })
    ~message ~remedy

let conflict reference message =
  Workspace_manager.Ownership_conflict
    (diagnostic reference message
       "Restore the correct workspace owner record or move the foreign \
        directory aside")

let secondary t reference = function
  | Native_outcome.Returned () -> ()
  | Native_outcome.Raised _ ->
      let error =
        Workspace_manager.Filesystem_error
          (diagnostic reference "Workspace release raised an unexpected defect"
             "Inspect the host filesystem and release diagnostics before \
              retrying")
      in
      (* Opaque callback values may themselves be errors. Never replace them. *)
      ignore (Native_outcome.capture (fun () -> t.report error))

let scoped t reference f =
  let primary = ref Pending in
  let release =
    Native_outcome.capture (fun () ->
        Eio.Switch.run (fun sw ->
            primary := Finished (Native_outcome.capture (fun () -> f sw))))
  in
  match !primary with
  | Finished outcome ->
      secondary t reference release;
      Native_outcome.resolve outcome
  | Pending -> (
      match release with
      | Native_outcome.Raised (ex, bt) -> Printexc.raise_with_backtrace ex bt
      | Native_outcome.Returned () ->
          invalid_arg "Workspace scope finished without entering its callback")

let owner_for reference directory =
  let identity = Directory.identity directory in
  match
    Workspace_owner.make ~scope:(Contract.scope reference)
      ~issue_id:(Contract.issue_id reference)
      ~identifier:(Contract.identifier reference)
      ~device:identity.Directory.device ~inode:identity.Directory.inode
  with
  | Ok owner -> Ok owner
  | Error reason -> Error (conflict reference reason)

let read_owner reference guard =
  let* bytes = Directory.read_owner guard in
  match bytes with
  | None -> Ok None
  | Some bytes -> (
      match Workspace_owner.parse bytes with
      | Ok owner -> Ok (Some owner)
      | Error reason ->
          Error (conflict reference ("Invalid workspace owner: " ^ reason)))

let verify reference guard directory expected =
  let* () = Directory.revalidate guard directory in
  let* actual = read_owner reference guard in
  match actual with
  | Some actual when Workspace_owner.equal actual expected -> Ok ()
  | None | Some _ ->
      Error
        (conflict reference
           "Workspace owner does not match this issue and directory")

let lease t reference guard directory owner =
  let path =
    Workspace_path_posix.create ~directory
      ~validate:(fun () -> verify reference guard directory owner)
      ~report:t.report
  in
  { reference; guard; directory; owner; phase = Active path }

let with_owned t origin lease f =
  let outcome =
    Native_outcome.capture (fun () ->
        Eio.Fiber.check ();
        f origin lease)
  in
  let release =
    match lease.phase with
    | Retired _ -> Native_outcome.Returned ()
    | Active path -> Native_outcome.capture (fun () -> t.close_path path)
  in
  secondary t lease.reference release;
  Native_outcome.resolve outcome

let path lease =
  match lease.phase with
  | Active path ->
      let* () = Workspace_path_posix.check path in
      Ok path
  | Retired _ ->
      Error
        (conflict lease.reference
           "Workspace lease is retired; acquire a fresh lease")

let remove t lease =
  match lease.phase with
  | Retired outcome -> Native_outcome.resolve outcome
  | Active path -> (
      (* Join children first, then verify their final filesystem observation. *)
      let closed = Native_outcome.capture (fun () -> t.close_path path) in
      let removal =
        Native_outcome.capture (fun () ->
            Eio.Cancel.protect (fun () ->
                let* () =
                  verify lease.reference lease.guard lease.directory lease.owner
                in
                Directory.remove lease.guard lease.directory))
      in
      (* Closure has joined even when its handler raised. Retain the physical
         removal outcome once; reporting cannot skip or replace that outcome. *)
      lease.phase <- Retired removal;
      match removal with
      | Native_outcome.Returned (Ok ()) ->
          Native_outcome.resolve closed;
          Ok ()
      | Native_outcome.Returned (Error _) | Native_outcome.Raised _ ->
          secondary t lease.reference closed;
          Native_outcome.resolve removal)

let rollback t reference guard fresh =
  let directory = Directory.directory fresh in
  let cleanup =
    Native_outcome.capture (fun () ->
        Eio.Cancel.protect (fun () ->
            let result =
              let* owner = read_owner reference guard in
              match owner with
              | None -> Directory.discard_unpublished guard fresh
              | Some actual ->
                  let* expected = owner_for reference directory in
                  if Workspace_owner.equal actual expected then
                    Directory.remove guard directory
                  else
                    Error
                      (conflict reference
                         "Rollback cannot remove a foreign ownership record")
            in
            match result with
            | Ok () -> ()
            | Error error -> t.report error))
  in
  secondary t reference cleanup

let acquire t ~sw intent root guard reference =
  let* directory = Directory.lookup ~sw root (Contract.key reference) in
  let* owner = read_owner reference guard in
  match (directory, owner, intent) with
  | Some directory, Some actual, _ ->
      let* expected = owner_for reference directory in
      let* () = verify reference guard directory expected in
      if Workspace_owner.equal actual expected then
        Ok (Some (Reused, lease t reference guard directory expected))
      else
        Error
          (conflict reference
             "Workspace belongs to a different issue or directory")
  | Some _, None, _ ->
      Error (conflict reference "Existing workspace has no ownership record")
  | None, Some _, _ ->
      Error (conflict reference "Ownership record names a missing workspace")
  | None, None, Directory.Inspect -> Ok None
  | None, None, Directory.Prepare ->
      let* fresh = Directory.create ~sw root (Contract.key reference) in
      let directory = Directory.directory fresh in
      let outcome =
        Native_outcome.capture (fun () ->
            let* owner = owner_for reference directory in
            let* () = Directory.publish_owner guard owner in
            let* () = verify reference guard directory owner in
            Ok (Some (Created, lease t reference guard directory owner)))
      in
      (match outcome with
      | Native_outcome.Returned (Ok _) -> ()
      | Native_outcome.Returned (Error _) | Native_outcome.Raised _ ->
          rollback t reference guard fresh);
      Native_outcome.resolve outcome

let inspect_unlocked ~sw root reference =
  let* directory = Directory.lookup ~sw root (Contract.key reference) in
  match directory with
  | None -> Ok None
  | Some _ ->
      Error
        (conflict reference "Existing workspace has no protected ownership lock")

let bracket t intent reference f =
  scoped t reference (fun sw ->
      let root = Workspace_settings.root (Contract.settings reference) in
      let* root = Directory.open_root ~fs:t.fs ~sw intent root in
      match root with
      | None -> Ok (f None)
      | Some root -> (
          let* guard =
            Directory.open_key ~sw root (Contract.key reference) intent
          in
          let* acquired =
            match guard with
            | None -> inspect_unlocked ~sw root reference
            | Some guard -> acquire t ~sw intent root guard reference
          in
          match acquired with
          | None -> Ok (f None)
          | Some (origin, lease) ->
              Ok
                (with_owned t origin lease (fun origin lease ->
                     f (Some (origin, lease))))))

let with_existing t reference f =
  bracket t Directory.Inspect reference (function
    | None -> f None
    | Some (_, lease) -> f (Some lease))

let with_lease t reference f =
  let* result =
    bracket t Directory.Prepare reference (function
      | None ->
          Error
            (conflict reference
               "Workspace preparation did not acquire a directory")
      | Some (origin, lease) -> Ok (f origin lease))
  in
  result
