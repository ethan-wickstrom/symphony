module Store = Workspace_store_posix
module Contract = Store.Contract

let checked = function
  | Ok value -> value
  | Error reason -> Alcotest.fail reason

let error_text = function
  | Workspace_manager.Invalid_key diagnostic
  | Workspace_manager.Unsafe_path diagnostic
  | Workspace_manager.Ownership_conflict diagnostic
  | Workspace_manager.Filesystem_error diagnostic
  | Workspace_manager.Hook_failed diagnostic
  | Workspace_manager.Hook_timeout diagnostic -> Diagnostic.render diagnostic

let acquired = function
  | Ok value -> value
  | Error error -> Alcotest.fail (error_text error)

let rejected = function
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "Foreign or stale authority was accepted"

let reference root ?(scope = "native-test") ?(id = "opaque-1")
    ?(identifier = "SYM-2") () =
  let base = checked (Absolute_path.parse root) in
  let env = checked (Environment.of_bindings ~temp_dir:base []) in
  let workflow_file = checked (Workflow_path.resolve ~base "WORKFLOW.md") in
  let config =
    checked
      (Config_value.parse
         (Yojson.Safe.to_string
            (`Assoc [ ("workspace", `Assoc [ ("root", `String root) ]) ])))
  in
  let settings =
    match Workspace_settings.parse ~env ~workflow_file config with
    | Ok settings -> settings
    | Error errors ->
        Alcotest.fail
          (String.concat "\n"
             (List.map Diagnostic.render (Nonempty_list.to_list errors)))
  in
  acquired
    (Contract.reference ~settings
       ~env:(Environment.child env ~allow:[] ~deny:[])
       ~scope:(checked (Tracker_scope.parse scope))
       ~issue_id:(checked (Issue_id.parse id))
       ~identifier:(checked (Issue_identifier.parse identifier)))

let with_fixture f =
  Eio_posix.run (fun env ->
      let base = Filename.temp_file "symphony-store-" "" in
      Unix.unlink base;
      Unix.mkdir base 0o700;
      let fs = Eio.Stdenv.fs env in
      Fun.protect
        (fun () ->
          let root = Filename.concat base "workspaces" in
          let errors = ref [] in
          let store =
            Store.create ~fs ~close_path:Workspace_path_posix.close
              ~report:(fun error -> errors := error :: !errors)
          in
          f ~base ~root ~fs store errors)
        ~finally:(fun () -> Eio.Path.rmtree (Eio.Path.( / ) fs base)))

let entry root reference =
  Filename.concat root (Workspace_key.text (Contract.key reference))

let owner_file root reference =
  Filename.concat
    (Filename.concat
       (Filename.concat root "@symphony")
       (Workspace_key.text (Contract.key reference)))
    "owner"

let lock_file root reference =
  Filename.concat (Filename.dirname (owner_file root reference)) "lock"

let write path text =
  let channel = open_out_bin path in
  Fun.protect
    (fun () -> output_string channel text)
    ~finally:(fun () -> close_out channel)

let exists path =
  try
    ignore (Unix.lstat path);
    true
  with Unix.Unix_error (Unix.ENOENT, _, _) -> false

let missing () =
  with_fixture (fun ~base ~root ~fs:_ store _ ->
      let issue = reference root () in
      let before = Array.to_list (Sys.readdir base) in
      acquired
        (Store.with_existing store issue (function
          | None -> ()
          | Some _ -> Alcotest.fail "Missing root produced a lease"));
      Alcotest.(check (list string))
        "No filesystem changes" before
        (Array.to_list (Sys.readdir base)))

let lifecycle () =
  with_fixture (fun ~base:_ ~root ~fs:_ store errors ->
      let issue = reference root () in
      let original =
        acquired
          (Store.with_lease store issue (fun origin lease ->
               Alcotest.(check bool) "Created" true (origin = Store.Created);
               ignore (acquired (Store.path lease));
               (Unix.stat (entry root issue)).Unix.st_ino))
      in
      let lock_inode = (Unix.stat (lock_file root issue)).Unix.st_ino in
      acquired
        (Store.with_lease store issue (fun origin lease ->
             Alcotest.(check bool) "Reused" true (origin = Store.Reused);
             Alcotest.(check int)
               "Same directory" original
               (Unix.stat (entry root issue)).Unix.st_ino;
             acquired (Store.remove store lease);
             acquired (Store.remove store lease);
             rejected (Store.path lease)));
      Alcotest.(check bool)
        "Workspace removed" false
        (exists (entry root issue));
      Alcotest.(check bool)
        "Owner removed" false
        (exists (owner_file root issue));
      Alcotest.(check int)
        "Permanent lock" lock_inode
        (Unix.stat (lock_file root issue)).Unix.st_ino;
      acquired
        (Store.with_existing store issue (function
          | None -> ()
          | Some _ -> Alcotest.fail "Removed workspace exists"));
      acquired
        (Store.with_lease store issue (fun origin _ ->
             Alcotest.(check bool) "Recreated" true (origin = Store.Created)));
      Alcotest.(check int) "No cleanup errors" 0 (List.length !errors))

let foreign () =
  with_fixture (fun ~base:_ ~root ~fs:_ store _ ->
      let issue = reference root () in
      acquired (Store.with_lease store issue (fun _ _ -> ()));
      List.iter
        (fun foreign ->
          rejected
            (Store.with_lease store foreign (fun _ _ ->
                 Alcotest.fail "Foreign callback"));
          rejected
            (Store.with_existing store foreign (fun _ ->
                 Alcotest.fail "Foreign inspection")))
        [
          reference root ~scope:"another-provider" ();
          reference root ~id:"recreated-issue" ();
        ];
      let hashed = reference root ~identifier:"SYM/9" () in
      acquired (Store.with_lease store hashed (fun _ _ -> ()));
      let literal =
        reference root ~identifier:(Workspace_key.text (Contract.key hashed)) ()
      in
      Alcotest.(check string)
        "Same physical key"
        (Workspace_key.text (Contract.key hashed))
        (Workspace_key.text (Contract.key literal));
      rejected
        (Store.with_lease store literal (fun _ _ ->
             Alcotest.fail "Identifier alias adopted"));
      acquired (Store.with_lease store issue (fun _ _ -> ())))

let unknown () =
  with_fixture (fun ~base:_ ~root ~fs:_ store _ ->
      Unix.mkdir root 0o700;
      let issue = reference root () in
      Unix.mkdir (entry root issue) 0o700;
      let marker = Filename.concat (entry root issue) "foreign" in
      write marker "preserve";
      rejected
        (Store.with_existing store issue (fun _ ->
             Alcotest.fail "Unowned inspection"));
      Alcotest.(check bool)
        "Inspection creates no metadata" false
        (exists (Filename.concat root "@symphony"));
      rejected
        (Store.with_lease store issue (fun _ _ ->
             Alcotest.fail "Unowned directory adopted"));
      Alcotest.(check bool) "Foreign contents preserved" true (exists marker))

let displacement () =
  with_fixture (fun ~base:_ ~root ~fs:_ store _ ->
      let issue = reference root () in
      acquired
        (Store.with_lease store issue (fun _ lease ->
             let path = acquired (Store.path lease) in
             Unix.rename (entry root issue) (entry root issue ^ ".moved");
             Unix.mkdir (entry root issue) 0o700;
             let marker = Filename.concat (entry root issue) "replacement" in
             write marker "preserve";
             rejected (Store.path lease);
             rejected
               (Workspace_path_posix.with_child path ~on_error:Fun.id
                  (fun ~sw:_ _ -> Alcotest.fail "Displaced child launched"));
             rejected (Store.remove store lease);
             Alcotest.(check bool) "Replacement preserved" true (exists marker))))

let expired () =
  with_fixture (fun ~base:_ ~root ~fs:_ store _ ->
      let issue = reference root () in
      let escaped =
        acquired
          (Store.with_lease store issue (fun _ lease ->
               acquired (Store.path lease)))
      in
      rejected (Workspace_path_posix.check escaped);
      rejected
        (Workspace_path_posix.with_child escaped ~on_error:Fun.id
           (fun ~sw:_ _ -> Alcotest.fail "Expired child launched"));
      acquired (Store.with_lease store issue (fun _ _ -> ())))

let child_join () =
  with_fixture (fun ~base:_ ~root ~fs:_ store _ ->
      let issue = reference root () in
      let trace = ref [] in
      let record event = trace := event :: !trace in
      Eio.Switch.run (fun sw ->
          let started, ready = Eio.Promise.create () in
          acquired
            (Store.with_lease store issue (fun _ lease ->
                 let path = acquired (Store.path lease) in
                 Eio.Fiber.fork ~sw (fun () ->
                     rejected
                       (Workspace_path_posix.with_child path ~on_error:Fun.id
                          (fun ~sw:_ _ ->
                            Fun.protect
                              (fun () ->
                                record "child admitted";
                                Eio.Promise.resolve ready ();
                                Eio.Fiber.await_cancel ())
                              ~finally:(fun () ->
                                Eio.Cancel.protect (fun () ->
                                    record "child closed")))));
                 Eio.Promise.await started;
                 record "callback returned"));
          record "lease released");
      Alcotest.(check (list string))
        "Child closes before owner releases"
        [
          "child admitted";
          "callback returned";
          "child closed";
          "lease released";
        ]
        (List.rev !trace);
      acquired (Store.with_lease store issue (fun _ _ -> ())))

exception Original_defect

let failed_publication () =
  with_fixture (fun ~base:_ ~root ~fs store _ ->
      let issue = reference root () in
      Eio.Switch.run (fun sw ->
          let physical =
            match
              acquired
                (Workspace_directory.open_root ~fs ~sw
                   Workspace_directory.Prepare
                   (checked (Absolute_path.parse root)))
            with
            | Some root -> root
            | None -> Alcotest.fail "Root preparation missing"
          in
          ignore
            (acquired
               (Workspace_directory.open_key ~sw physical (Contract.key issue)
                  Workspace_directory.Prepare)));
      Unix.mkdir
        (Filename.concat
           (Filename.dirname (owner_file root issue))
           "owner.pending")
        0o700;
      rejected
        (Store.with_lease store issue (fun _ _ ->
             Alcotest.fail "Failed publication granted authority"));
      Alcotest.(check bool)
        "Unpublished newly created directory rolled back" false
        (exists (entry root issue)))

let callback_defect () =
  with_fixture (fun ~base:_ ~root ~fs:_ store _ ->
      let issue = reference root () in
      let outcome =
        Native_outcome.capture (fun () ->
            Store.with_lease store issue (fun _ _ -> raise Original_defect))
      in
      (match outcome with
      | Native_outcome.Raised (Original_defect, _) -> ()
      | Native_outcome.Raised _ | Native_outcome.Returned _ ->
          Alcotest.fail "Primary defect replaced");
      acquired
        (Store.with_lease store issue (fun origin _ ->
             Alcotest.(check bool)
               "Callback failure preserves workspace" true
               (origin = Store.Reused))))

exception Close_defect of unit ref
exception Reporter_defect

type close_fault = Armed | Fired

let removal_after_close_defect () =
  with_fixture (fun ~base:_ ~root ~fs _ _ ->
      let issue = reference root () in
      let original = Close_defect (ref ()) in
      let fault = ref Armed in
      let traces = ref [] in
      let joined, closed = Eio.Promise.create () in
      let close_path path =
        Workspace_path_posix.close path;
        match !fault with
        | Fired -> ()
        | Armed -> (
            fault := Fired;
            Alcotest.(check bool)
              "Real loan joined before close defect" true
              (Eio.Promise.is_resolved joined);
            rejected (Workspace_path_posix.check path);
            try raise original
            with exn ->
              let trace = Printexc.get_raw_backtrace () in
              traces := [ trace ];
              Printexc.raise_with_backtrace exn trace)
      in
      let store = Store.create ~fs ~close_path ~report:(fun _ -> ()) in
      let lock_inode =
        Eio.Switch.run (fun sw ->
            let started, ready = Eio.Promise.create () in
            acquired
              (Store.with_lease store issue (fun _ lease ->
                   let path = acquired (Store.path lease) in
                   let inode = (Unix.stat (lock_file root issue)).Unix.st_ino in
                   Eio.Fiber.fork ~sw (fun () ->
                       rejected
                         (Workspace_path_posix.with_child path ~on_error:Fun.id
                            (fun ~sw:_ _ ->
                              Fun.protect
                                (fun () ->
                                  Eio.Promise.resolve ready ();
                                  Eio.Fiber.await_cancel ())
                                ~finally:(fun () ->
                                  Eio.Cancel.protect (fun () ->
                                      Eio.Promise.resolve closed ())))));
                   Eio.Promise.await started;
                   let outcome =
                     Native_outcome.capture (fun () -> Store.remove store lease)
                   in
                   (match outcome with
                   | Native_outcome.Raised (observed, trace) -> (
                       Alcotest.(check bool)
                         "Close exception identity" true (observed == original);
                       match !traces with
                       | [ expected ] ->
                           Alcotest.(check bool)
                             "Nonempty close backtrace" true
                             (Printexc.raw_backtrace_length expected > 0);
                           Alcotest.(check bool)
                             "Original close backtrace retained" true
                             (String.starts_with
                                ~prefix:
                                  (Printexc.raw_backtrace_to_string expected)
                                (Printexc.raw_backtrace_to_string trace))
                       | [] | _ :: _ ->
                           Alcotest.fail "Close backtrace was not captured")
                   | Native_outcome.Returned _ ->
                       Alcotest.fail "Close defect disappeared");
                   Alcotest.(check bool)
                     "Directory removed before close defect propagates" false
                     (exists (entry root issue));
                   Alcotest.(check bool)
                     "Owner removed before close defect propagates" false
                     (exists (owner_file root issue));
                   acquired (Store.remove store lease);
                   rejected (Store.path lease);
                   inode)))
      in
      acquired
        (Store.with_existing store issue (function
          | None -> ()
          | Some _ -> Alcotest.fail "Removed workspace remains"));
      acquired
        (Store.with_lease store issue (fun origin _ ->
             Alcotest.(check bool)
               "Permanent lock reacquired for recreation" true
               (origin = Store.Created)));
      Alcotest.(check int)
        "Permanent lock identity preserved" lock_inode
        (Unix.stat (lock_file root issue)).Unix.st_ino)

let removal_error_is_primary () =
  with_fixture (fun ~base:_ ~root ~fs _ _ ->
      let issue = reference root () in
      let fault = ref Armed in
      let reports = ref [] in
      let close_path path =
        Workspace_path_posix.close path;
        match !fault with
        | Fired -> ()
        | Armed ->
            fault := Fired;
            raise (Close_defect (ref ()))
      in
      let store =
        Store.create ~fs ~close_path ~report:(fun error ->
            reports := error :: !reports;
            raise Reporter_defect)
      in
      let moved = entry root issue ^ ".moved" in
      let marker = Filename.concat (entry root issue) "replacement" in
      acquired
        (Store.with_lease store issue (fun _ lease ->
             Unix.rename (entry root issue) moved;
             Unix.mkdir (entry root issue) 0o700;
             write marker "preserve";
             let result =
               Native_outcome.capture (fun () -> Store.remove store lease)
             in
             (match result with
             | Native_outcome.Returned
                 (Error (Workspace_manager.Unsafe_path _ as primary)) -> (
                 match Store.remove store lease with
                 | Error repeated ->
                     Alcotest.(check bool)
                       "Removal error identity retained" true
                       (primary == repeated)
                 | Ok () -> Alcotest.fail "Repeated failed removal succeeded")
             | Native_outcome.Returned
                 (Error
                    ( Workspace_manager.Invalid_key _
                    | Workspace_manager.Ownership_conflict _
                    | Workspace_manager.Filesystem_error _
                    | Workspace_manager.Hook_failed _
                    | Workspace_manager.Hook_timeout _ )) ->
                 Alcotest.fail "Filesystem verification error was replaced"
             | Native_outcome.Returned (Ok ()) ->
                 Alcotest.fail "Displaced directory was removed"
             | Native_outcome.Raised _ ->
                 Alcotest.fail "Close or reporter defect replaced removal error");
             Alcotest.(check int)
               "Close defect reported once despite reporter defect" 1
               (List.length !reports);
             Alcotest.(check bool)
               "Replacement contents preserved" true (exists marker);
             Alcotest.(check bool)
               "Original directory preserved" true (exists moved);
             Alcotest.(check bool)
               "Owner record preserved on failed removal" true
               (exists (owner_file root issue))));
      Unix.unlink marker;
      Unix.rmdir (entry root issue);
      Unix.rename moved (entry root issue);
      acquired
        (Store.with_lease store issue (fun origin lease ->
             Alcotest.(check bool)
               "Lock reacquired after failed removal" true
               (origin = Store.Reused);
             acquired (Store.remove store lease))))

let suite =
  List.map
    (fun (name, test) -> Alcotest.test_case name `Quick test)
    [
      ("missing inspection is identity", missing);
      ("create reuse cleanup and permanent lock", lifecycle);
      ("foreign owners and literal hash alias", foreign);
      ("unknown directories preserved", unknown);
      ("displacement rejects effects", displacement);
      ("escaped path is revoked", expired);
      ("child join precedes lease release", child_join);
      ("failed publication rolls back new directory", failed_publication);
      ("callback defect releases ownership", callback_defect);
      ( "close defect cannot skip joined workspace removal",
        removal_after_close_defect );
      ( "removal error survives close and reporter defects",
        removal_error_is_primary );
    ]
