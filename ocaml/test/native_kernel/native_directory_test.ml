module D = Workspace_directory

let control_name = "@symphony"
let lock_name = "lock"
let owner_name = "owner"

let error_text = function
  | Workspace_manager.Invalid_key diagnostic
  | Workspace_manager.Unsafe_path diagnostic
  | Workspace_manager.Ownership_conflict diagnostic
  | Workspace_manager.Filesystem_error diagnostic
  | Workspace_manager.Hook_failed diagnostic
  | Workspace_manager.Hook_timeout diagnostic -> Diagnostic.render diagnostic

let checked = function
  | Ok value -> value
  | Error error -> Alcotest.fail (error_text error)

let parsed = function
  | Ok value -> value
  | Error error -> Alcotest.fail error

let present = function
  | Some value -> value
  | None -> Alcotest.fail "Expected an acquired handle"

let rejected label result =
  Alcotest.(check bool) label true (Result.is_error result)

let key text =
  Workspace_key.of_identifier (parsed (Issue_identifier.parse text)) |> parsed

let absolute text = parsed (Absolute_path.parse text)
let names path = Sys.readdir path |> Array.to_list |> List.sort String.compare

let metadata path workspace =
  Filename.concat
    (Filename.concat path control_name)
    (Workspace_key.text workspace)

let leaf path workspace name = Filename.concat (metadata path workspace) name

let write path text =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel text);
  Unix.chmod path 0o600

let read path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () ->
      let buffer = Buffer.create 128 in
      let rec loop () =
        match input_line channel with
        | line ->
            Buffer.add_string buffer line;
            loop ()
        | exception End_of_file -> Buffer.contents buffer
      in
      loop ())

let with_fixture fn =
  let base = Filename.temp_file "symphony-directory-" "" in
  Unix.unlink base;
  Unix.mkdir base 0o700;
  Eio_posix.run (fun env ->
      let fs = Eio.Stdenv.fs env in
      Fun.protect
        ~finally:(fun () ->
          Eio.Cancel.protect (fun () ->
              Eio.Path.rmtree (Eio.Path.( / ) fs base)))
        (fun () -> fn fs base))

let with_root fs base fn =
  let path = Filename.concat base "work" in
  Eio.Switch.run (fun sw ->
      let root =
        present (checked (D.open_root ~fs ~sw D.Prepare (absolute path)))
      in
      fn sw root path)

let owner_for text directory =
  let identity = D.identity directory in
  parsed
    (Workspace_owner.make
       ~scope:(parsed (Tracker_scope.parse "linear:project-kernel"))
       ~issue_id:(parsed (Issue_id.parse "opaque-kernel-id"))
       ~identifier:(parsed (Issue_identifier.parse text))
       ~device:identity.D.device ~inode:identity.D.inode)

let with_owned fs base text fn =
  with_root fs base (fun sw root path ->
      let workspace = key text in
      let guard = present (checked (D.open_key ~sw root workspace D.Prepare)) in
      let directory = D.directory (checked (D.create ~sw root workspace)) in
      let owner = owner_for text directory in
      checked (D.publish_owner guard owner);
      fn sw root path workspace guard directory owner)

let inspect_missing () =
  with_fixture (fun fs base ->
      let path = Filename.concat base "missing" in
      Eio.Switch.run (fun sw ->
          Alcotest.(check bool)
            "no root" true
            (Option.is_none
               (checked (D.open_root ~fs ~sw D.Inspect (absolute path)))));
      Alcotest.(check (list string))
        "root inspection writes nothing" [] (names base);
      let path = Filename.concat base "work" in
      Unix.mkdir path 0o755;
      Eio.Switch.run (fun sw ->
          let root =
            present (checked (D.open_root ~fs ~sw D.Inspect (absolute path)))
          in
          let workspace = key "SYM-1" in
          Alcotest.(check bool)
            "no metadata" true
            (Option.is_none (checked (D.open_key ~sw root workspace D.Inspect)));
          Alcotest.(check bool)
            "no workspace" true
            (Option.is_none (checked (D.lookup ~sw root workspace))));
      Alcotest.(check (list string))
        "key inspection writes nothing" [] (names path))

let create_and_owner () =
  with_fixture (fun fs base ->
      with_owned fs base "SYM-2"
        (fun sw root path workspace guard directory owner ->
          let native = Unix.LargeFile.stat (D.display directory) in
          let identity = D.identity directory in
          Alcotest.(check int64)
            "device"
            (Int64.of_int native.Unix.LargeFile.st_dev)
            identity.D.device;
          Alcotest.(check int64)
            "inode"
            (Int64.of_int native.Unix.LargeFile.st_ino)
            identity.D.inode;
          Alcotest.(check string)
            "canonical owner"
            (Workspace_owner.encode owner)
            (present (checked (D.read_owner guard)));
          checked (D.revalidate guard directory);
          rejected "exclusive creation never adopts"
            (D.create ~sw root workspace);
          Alcotest.(check int)
            "metadata mode" 0o700
            (Unix.stat (metadata path workspace)).Unix.st_perm;
          Alcotest.(check int)
            "owner mode" 0o600
            (Unix.stat (leaf path workspace owner_name)).Unix.st_perm;
          let copy = present (checked (D.lookup ~sw root workspace)) in
          Alcotest.(check bool)
            "repeated lookup same identity" true
            (D.identity directory = D.identity copy)))

let rec wait_child pid =
  match Unix.waitpid [] pid with
  | _, status -> status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_child pid

let probe_lock path expectation =
  (* Python is an independent syscall oracle; no Symphony process code is used. *)
  let script =
    "import fcntl,os,sys\n\
     fd=os.open(sys.argv[1],os.O_RDWR)\n\
     try:\n\
    \ fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)\n\
    \ busy=False\n\
     except BlockingIOError:\n\
    \ busy=True\n\
     os.close(fd)\n\
     sys.exit(0 if busy==(sys.argv[2]=='busy') else 7)\n"
  in
  let status =
    Eio_unix.run_in_systhread (fun () ->
        let argv = [| "env"; "python3"; "-c"; script; path; expectation |] in
        let pid =
          Unix.create_process "/usr/bin/env" argv Unix.stdin Unix.stdout
            Unix.stderr
        in
        wait_child pid)
  in
  Alcotest.(check bool)
    "independent process lock result" true (status = Unix.WEXITED 0)

let lock_contention () =
  with_fixture (fun fs base ->
      with_root fs base (fun _ root path ->
          let workspace = key "SYM-3" in
          Eio.Switch.run (fun sw ->
              ignore
                (present (checked (D.open_key ~sw root workspace D.Prepare)));
              Eio.Switch.run (fun other ->
                  rejected "same-process contention"
                    (D.open_key ~sw:other root workspace D.Prepare));
              probe_lock (leaf path workspace lock_name) "busy");
          probe_lock (leaf path workspace lock_name) "free";
          Eio.Switch.run (fun sw ->
              ignore
                (present (checked (D.open_key ~sw root workspace D.Inspect))))))

let unsafe_roots () =
  with_fixture (fun fs base ->
      let target = Filename.concat base "target" in
      Unix.mkdir target 0o700;
      let link = Filename.concat base "link" in
      Unix.symlink target link;
      Eio.Switch.run (fun sw ->
          rejected "root symlink"
            (D.open_root ~fs ~sw D.Prepare (absolute link)));
      Unix.chmod target 0o777;
      Eio.Switch.run (fun sw ->
          rejected "writable root"
            (D.open_root ~fs ~sw D.Inspect (absolute target)));
      Unix.chmod target 0o700)

let metadata_symlinks () =
  with_fixture (fun fs base ->
      with_root fs base (fun sw root path ->
          let workspace = key "SYM-4" in
          let outside = Filename.concat base "outside" in
          Unix.mkdir outside 0o700;
          let control = Filename.concat path control_name in
          Unix.symlink outside control;
          rejected "control symlink" (D.open_key ~sw root workspace D.Prepare);
          Unix.unlink control;
          Unix.mkdir control 0o700;
          Unix.symlink outside (metadata path workspace);
          rejected "key symlink" (D.open_key ~sw root workspace D.Prepare);
          Unix.unlink (metadata path workspace);
          Unix.mkdir (metadata path workspace) 0o700;
          let target = Filename.concat outside "file" in
          write target "untouched";
          Unix.symlink target (leaf path workspace lock_name);
          rejected "lock symlink" (D.open_key ~sw root workspace D.Prepare);
          Alcotest.(check string)
            "outside target unchanged" "untouched" (read target)))

let linked_metadata () =
  with_fixture (fun fs base ->
      with_owned fs base "SYM-5"
        (fun _ _ path workspace guard directory owner ->
          let owner_path = leaf path workspace owner_name in
          let extra = Filename.concat base "linked-owner" in
          Unix.link owner_path extra;
          rejected "hardlinked owner" (D.read_owner guard);
          rejected "publication rejects linked target"
            (D.publish_owner guard owner);
          Alcotest.(check string)
            "linked record preserved"
            (Workspace_owner.encode owner)
            (read owner_path);
          Unix.unlink extra;
          checked (D.revalidate guard directory)));
  with_fixture (fun fs base ->
      with_root fs base (fun sw root path ->
          let workspace = key "SYM-6" in
          Unix.mkdir (Filename.concat path control_name) 0o700;
          Unix.mkdir (metadata path workspace) 0o700;
          let lock = leaf path workspace lock_name in
          write lock "";
          Unix.link lock (Filename.concat base "linked-lock");
          rejected "hardlinked lock" (D.open_key ~sw root workspace D.Prepare)))

let displaced_entries () =
  with_fixture (fun fs base ->
      with_owned fs base "SYM-7" (fun _ _ path workspace guard directory _ ->
          let original = D.display directory in
          Unix.rename original (Filename.concat path "old-workspace");
          Unix.mkdir original 0o700;
          write (Filename.concat original "marker") "foreign";
          rejected "displaced workspace" (D.revalidate guard directory);
          rejected "never remove replacement" (D.remove guard directory);
          Alcotest.(check string)
            "replacement retained" "foreign"
            (read (Filename.concat original "marker"));
          let lock = leaf path workspace lock_name in
          Unix.rename lock (leaf path workspace "old-lock");
          write lock "";
          rejected "displaced lock" (D.read_owner guard)))

let owner_bounds () =
  with_fixture (fun fs base ->
      with_owned fs base "SYM-8" (fun _ _ path workspace guard _ owner ->
          let owner_path = leaf path workspace owner_name in
          write owner_path (String.make Workspace_owner.max_bytes ' ');
          Alcotest.(check int)
            "exact bound accepted" Workspace_owner.max_bytes
            (String.length (present (checked (D.read_owner guard))));
          write owner_path (String.make (Workspace_owner.max_bytes + 1) ' ');
          rejected "extra byte rejected" (D.read_owner guard);
          write owner_path (Workspace_owner.encode owner);
          Unix.mkdir (leaf path workspace "owner.pending") 0o700;
          rejected "unsafe pending publication" (D.publish_owner guard owner);
          Alcotest.(check string)
            "last complete owner retained"
            (Workspace_owner.encode owner)
            (read owner_path)))

let anchored_removal () =
  with_fixture (fun fs base ->
      with_owned fs base "SYM-9" (fun _ _ path workspace guard directory _ ->
          let outside = Filename.concat base "outside-marker" in
          write outside "survives";
          let nested = Filename.concat (D.display directory) "nested" in
          Unix.mkdir nested 0o700;
          write (Filename.concat nested "file") "remove";
          Unix.symlink outside (Filename.concat nested "link");
          Unix.link outside (Filename.concat (D.display directory) "hardlink");
          checked (D.remove guard directory);
          Alcotest.(check string)
            "outside target retained" "survives" (read outside);
          Alcotest.(check bool)
            "workspace gone" false
            (Sys.file_exists (D.display directory));
          Alcotest.(check bool)
            "owner cleared" true
            (Option.is_none (checked (D.read_owner guard)));
          Alcotest.(check bool)
            "permanent lock retained" true
            (Sys.file_exists (leaf path workspace lock_name));
          Alcotest.(check bool)
            "key directory retained" true
            (Sys.is_directory (metadata path workspace));
          checked (D.remove guard directory)))

exception Callback_defect

let cwd_borrow () =
  with_fixture (fun fs base ->
      with_owned fs base "SYM-10" (fun _ _ _ _ guard directory _ ->
          let raised =
            try
              D.with_cwd directory (fun fd ->
                  Eio.Fiber.yield ();
                  Eio_unix.Fd.use_exn "oracle-fstat" fd (fun raw ->
                      ignore (Unix.fstat raw));
                  raise Callback_defect)
            with Callback_defect -> true
          in
          Alcotest.(check bool) "original callback defect" true raised;
          checked (D.revalidate guard directory);
          let value =
            D.with_cwd directory (fun _ ->
                Eio.Fiber.yield ();
                "borrowed")
          in
          Alcotest.(check string) "callback value preserved" "borrowed" value))

let canceled_scope () =
  with_fixture (fun fs base ->
      with_root fs base (fun _ root path ->
          let workspace = key "SYM-11" in
          let ready, resolve = Eio.Promise.create () in
          let ended =
            Eio.Fiber.first
              (fun () ->
                Eio.Switch.run (fun sw ->
                    ignore
                      (present
                         (checked (D.open_key ~sw root workspace D.Prepare)));
                    let directory =
                      D.directory (checked (D.create ~sw root workspace))
                    in
                    Eio.Promise.resolve resolve directory;
                    Eio.Fiber.await_cancel ()))
              (fun () -> Eio.Promise.await ready)
          in
          let refused =
            try D.with_cwd ended (fun _ -> false)
            with Invalid_argument _ -> true
          in
          Alcotest.(check bool) "ended directory refuses callback" true refused;
          probe_lock (leaf path workspace lock_name) "free";
          Eio.Switch.run (fun sw ->
              ignore
                (present (checked (D.open_key ~sw root workspace D.Inspect))))))

let maximal_key () =
  with_fixture (fun fs base ->
      with_owned fs base (String.make 255 'A')
        (fun _ _ path workspace guard directory _ ->
          Alcotest.(check int)
            "actual key length" 255
            (String.length (Workspace_key.text workspace));
          Alcotest.(check string)
            "metadata uses actual component"
            (Workspace_key.text workspace)
            (Filename.basename (metadata path workspace));
          probe_lock (leaf path workspace lock_name) "busy";
          checked (D.revalidate guard directory);
          checked (D.remove guard directory)))

let fresh_rollback () =
  with_fixture (fun fs base ->
      with_root fs base (fun sw root path ->
          let text = "SYM-12" in
          let workspace = key text in
          let guard =
            present (checked (D.open_key ~sw root workspace D.Prepare))
          in
          let fresh = checked (D.create ~sw root workspace) in
          let directory = D.directory fresh in
          write (Filename.concat (D.display directory) "unpublished") "discard";
          checked (D.discard_unpublished guard fresh);
          checked (D.discard_unpublished guard fresh);
          Alcotest.(check bool)
            "unpublished identity removed" false
            (Sys.file_exists (D.display directory));
          Alcotest.(check bool)
            "permanent lock remains" true
            (Sys.file_exists (leaf path workspace lock_name));
          let replacement = checked (D.create ~sw root workspace) in
          let replacement_dir = D.directory replacement in
          write
            (Filename.concat (D.display replacement_dir) "marker")
            "replacement";
          rejected "stale rollback cannot delete later creation"
            (D.discard_unpublished guard fresh);
          Alcotest.(check string)
            "replacement retained" "replacement"
            (read (Filename.concat (D.display replacement_dir) "marker"));
          checked (D.publish_owner guard (owner_for text replacement_dir));
          rejected "publication revokes unpublished rollback"
            (D.discard_unpublished guard replacement);
          checked (D.remove guard replacement_dir)))

let wide_removal () =
  with_fixture (fun fs base ->
      with_owned fs base "SYM-13" (fun _ _ _ _ guard directory _ ->
          let entry_count = 300 in
          List.init entry_count (fun index -> string_of_int index)
          |> List.iter (fun name ->
              write (Filename.concat (D.display directory) name) "entry");
          checked (D.remove guard directory);
          Alcotest.(check bool)
            "all cursor batches removed" false
            (Sys.file_exists (D.display directory))))

let depth_limit () =
  with_fixture (fun fs base ->
      with_owned fs base "SYM-14" (fun _ _ _ _ guard directory owner ->
          let depth = 130 in
          let _, paths =
            List.fold_left
              (fun (parent, paths) _ ->
                let child = Filename.concat parent "n" in
                Unix.mkdir child 0o700;
                (child, child :: paths))
              (D.display directory, [])
              (List.init depth Fun.id)
          in
          rejected "excessive nesting is a value" (D.remove guard directory);
          Alcotest.(check string)
            "depth failure retains owner"
            (Workspace_owner.encode owner)
            (present (checked (D.read_owner guard)));
          (match paths with
          | deepest :: parent :: _ ->
              Unix.rmdir deepest;
              Unix.rmdir parent
          | _ -> Alcotest.fail "Nested fixture is incomplete");
          checked (D.remove guard directory)))

let with_fifo_guard base fifo fn =
  let released = Filename.concat base "fifo-guard-released" in
  let guard_delay = "2" in
  let script =
    "import os,sys,time\n\
     from pathlib import Path\n\
     time.sleep(float(sys.argv[3]))\n\
     Path(sys.argv[2]).write_text('released')\n\
     fd=os.open(sys.argv[1],os.O_RDWR|os.O_NONBLOCK)\n\
     time.sleep(float(sys.argv[3]))\n\
     os.close(fd)\n"
  in
  let pid =
    Eio_unix.run_in_systhread (fun () ->
        Unix.create_process "/usr/bin/env"
          [| "env"; "python3"; "-c"; script; fifo; released; guard_delay |]
          Unix.stdin Unix.stdout Unix.stderr)
  in
  Fun.protect
    ~finally:(fun () ->
      Eio.Cancel.protect (fun () ->
          Eio_unix.run_in_systhread (fun () ->
              (* Retain the owned child's PID until signaling and sole reap. *)
              (try Unix.kill pid Sys.sigkill
               with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
              ignore (wait_child pid))))
    (fun () ->
      fn ();
      Alcotest.(check bool)
        "rejection precedes guard opening a writer" false
        (Sys.file_exists released))

let unsafe_result label = function
  | Error (Workspace_manager.Unsafe_path _) -> ()
  | Error
      (( Workspace_manager.Invalid_key _
       | Workspace_manager.Ownership_conflict _
       | Workspace_manager.Filesystem_error _
       | Workspace_manager.Hook_failed _
       | Workspace_manager.Hook_timeout _ ) as error) ->
      Alcotest.fail (label ^ ": " ^ error_text error)
  | Ok _ -> Alcotest.fail (label ^ ": granted authority")

let fifo_roots () =
  with_fixture (fun fs base ->
      let fifo = Filename.concat base "root-fifo" in
      Unix.mkfifo fifo 0o600;
      with_fifo_guard base fifo (fun () ->
          Eio.Switch.run (fun sw ->
              unsafe_result "FIFO root grants no directory authority"
                (D.open_root ~fs ~sw D.Inspect (absolute fifo))));
      Alcotest.(check bool)
        "FIFO root retained" true
        ((Unix.lstat fifo).Unix.st_kind = Unix.S_FIFO))

let fifo_owner () =
  with_fixture (fun fs base ->
      with_owned fs base "SYM-15" (fun _ _ path workspace guard directory _ ->
          let fifo = leaf path workspace owner_name in
          Unix.unlink fifo;
          Unix.mkfifo fifo 0o600;
          with_fifo_guard base fifo (fun () ->
              unsafe_result "FIFO owner is rejected before reading"
                (D.read_owner guard));
          Alcotest.(check bool)
            "FIFO owner retained" true
            ((Unix.lstat fifo).Unix.st_kind = Unix.S_FIFO);
          Alcotest.(check bool)
            "workspace retained" true
            (Sys.file_exists (D.display directory))))

let suite =
  [
    Alcotest.test_case "missing inspection changes no entries" `Quick
      inspect_missing;
    Alcotest.test_case "exclusive creation and exact owner identity" `Quick
      create_and_owner;
    Alcotest.test_case "same-process and cross-process locks release" `Quick
      lock_contention;
    Alcotest.test_case "root symlinks and writable roots fail" `Quick
      unsafe_roots;
    Alcotest.test_case "every metadata component is nofollow" `Quick
      metadata_symlinks;
    Alcotest.test_case "linked metadata grants no authority" `Quick
      linked_metadata;
    Alcotest.test_case "displaced identities retain foreign entries" `Quick
      displaced_entries;
    Alcotest.test_case "owner bounds and publication failure preserve record"
      `Quick owner_bounds;
    Alcotest.test_case "anchored removal retains permanent lock" `Quick
      anchored_removal;
    Alcotest.test_case "cwd borrowing preserves callback outcomes" `Quick
      cwd_borrow;
    Alcotest.test_case "cancellation releases locks and ends cwd loans" `Quick
      canceled_scope;
    Alcotest.test_case "maximal keys share the actual lock namespace" `Quick
      maximal_key;
    Alcotest.test_case
      "fresh rollback preserves replacements and published owners" `Quick
      fresh_rollback;
    Alcotest.test_case "wide cleanup crosses bounded cursor batches" `Quick
      wide_removal;
    Alcotest.test_case "depth errors retain ownership and permit retry" `Quick
      depth_limit;
    Alcotest.test_case "FIFO roots reject before a guard writer opens" `Quick
      fifo_roots;
    Alcotest.test_case "FIFO owners reject before a guard writer opens" `Quick
      fifo_owner;
  ]
