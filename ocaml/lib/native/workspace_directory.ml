module L = Eio_posix.Low_level
module Fd = Eio_unix.Fd

type intent = Prepare | Inspect
type identity = { device : int64; inode : int64 }
type handle = { fd : Fd.t; id : identity }

type root = {
  dir : handle;
  uid : int64;
  fs : Eio.Fs.dir_ty Eio.Path.t;
  path : Absolute_path.t;
}

type key_guard = {
  root : root;
  key : Workspace_key.t;
  control : handle;
  metadata : handle;
  lock : handle;
}

type directory = { root : root; key : Workspace_key.t; dir : handle }
type fresh = Fresh of directory
type kind = Directory | File

let control_name = "@symphony"
let lock_name = "lock"
let owner_name = "owner"
let pending_name = "owner.pending"
let directory_mode = 0o700
let file_mode = 0o600
let forbidden_root_write = 0o022
let removal_batch_size = 128
let max_removal_depth = 128
let ( let* ) = Result.bind

let directory_flags =
  let open! L.Open_flags in
  rdonly + directory + nofollow

let read_flags =
  let open! L.Open_flags in
  rdonly + nofollow

let prepare_lock_flags =
  let open! L.Open_flags in
  rdwr + nofollow + creat

let inspect_lock_flags =
  let open! L.Open_flags in
  rdwr + nofollow

let pending_flags =
  let open! L.Open_flags in
  wronly + creat + excl + nofollow

let root_label (root : root) = Absolute_path.display root.path

let key_label (root : root) key =
  Filename.concat (root_label root) (Workspace_key.text key)

let control_label (root : root) = Filename.concat (root_label root) control_name

let metadata_label (guard : key_guard) =
  Filename.concat (control_label guard.root) (Workspace_key.text guard.key)

let leaf_label (guard : key_guard) name =
  Filename.concat (metadata_label guard) name

let diagnostic label message remedy =
  Diagnostic.make ~site:(Diagnostic.Host label) ~message ~remedy

let unsafe label message =
  Error
    (Workspace_manager.Unsafe_path
       (diagnostic label message
          "Restore the checked entry and its protected permissions; do not use \
           symlinks."))

let conflict label message =
  Error
    (Workspace_manager.Ownership_conflict
       (diagnostic label message
          "Restore matching ownership metadata or choose a different workspace \
           root."))

let filesystem label message =
  Error
    (Workspace_manager.Filesystem_error
       (diagnostic label message
          "Check the named path's permissions and available filesystem \
           resources, then retry."))

(* Only this module's filesystem operations enter this catcher, never callbacks. *)
let is_symlink = function
  | Eio.Fs.E error -> (
      match error with
      | Eio.Fs.Symlink -> true
      | Eio.Fs.Already_exists _
      | Eio.Fs.Not_found _
      | Eio.Fs.Permission_denied _
      | Eio.Fs.File_too_large
      | Eio.Fs.Not_native _ -> false)
  | _ -> false

let boundary label fn =
  match Native_io.capture fn with
  | Ok value -> value
  | Error (Native_io.Unix (error, operation)) ->
      if error = Unix.ELOOP || error = Unix.ENOTDIR then
        unsafe label
          (operation
         ^ ": expected a nofollow directory or regular metadata file")
      else filesystem label (operation ^ ": " ^ Unix.error_message error)
  | Error (Native_io.Io (error, context)) ->
      if is_symlink error then
        unsafe label "A symbolic link cannot grant directory authority"
      else filesystem label (Printexc.to_string (Eio.Io (error, context)))

let missing fn =
  try Ok (Some (fn ()))
  with
  | Unix.Unix_error (Unix.ENOENT, _, _)
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _)
  ->
    Ok None

let stat fd =
  let buf = L.create_stat () in
  L.fstat ~buf fd;
  buf

let id buf = { device = L.dev buf; inode = L.ino buf }
let same_id a b = Int64.equal a.device b.device && Int64.equal a.inode b.inode
let handle fd = { fd; id = id (stat fd) }

let check_kind label expected buf =
  let matches =
    match expected with
    | Directory -> L.kind buf = `Directory
    | File -> L.kind buf = `Regular_file
  in
  if matches then Ok ()
  else unsafe label "The entry has the wrong filesystem kind"

let check_root label buf =
  let* () = check_kind label Directory buf in
  if L.perm buf land forbidden_root_write = 0 then Ok ()
  else unsafe label "The workspace root permits group or world writes"

let check_device label expected actual =
  if Int64.equal expected actual then Ok ()
  else
    Error
      (Workspace_manager.Unsafe_path
         (diagnostic label "The directory is on a different filesystem"
            "Use workspace directories on the root filesystem, then retry."))

let check_metadata (root : root) label expected buf =
  let* () = check_kind label expected buf in
  let mode =
    match expected with
    | Directory -> directory_mode
    | File -> file_mode
  in
  if not (Int64.equal (L.uid buf) root.uid) then
    unsafe label "Metadata UID differs from the root UID"
  else if not (Int64.equal (L.dev buf) root.dir.id.device) then
    unsafe label "Metadata is on a different filesystem"
  else if L.perm buf <> mode then
    unsafe label (Printf.sprintf "Metadata permissions must be %04o" mode)
  else
    match expected with
    | File when not (Int64.equal (L.nlink buf) 1L) ->
        unsafe label "Metadata must have exactly one hard link"
    | Directory | File -> Ok ()

let path_fd ~sw path =
  let resource = Eio.Path.open_in ~sw ~follow:false path in
  match Eio_unix.Resource.fd_opt resource with
  | Some fd -> Ok fd
  | None ->
      unsafe
        (Format.asprintf "%a" Eio.Path.pp path)
        "The filesystem backend supplies no POSIX descriptor"

let open_root ~fs ~sw intent path =
  let label = Absolute_path.display path in
  boundary label (fun () ->
      let location = Eio.Path.( / ) fs label in
      let* opened = missing (fun () -> path_fd ~sw location) in
      let* opened =
        match (opened, intent) with
        | None, Inspect -> Ok None
        | None, Prepare ->
            Eio.Path.mkdirs ~exists_ok:true ~perm:directory_mode location;
            let* fd = path_fd ~sw location in
            Ok (Some fd)
        | Some result, (Prepare | Inspect) -> Result.map Option.some result
      in
      match opened with
      | None -> Ok None
      | Some fd ->
          let buf = stat fd in
          let* () = check_root label buf in
          Ok (Some { dir = { fd; id = id buf }; uid = L.uid buf; fs; path }))

let verify_id label expected buf =
  if same_id expected (id buf) then Ok ()
  else unsafe label "The entry no longer names the acquired device and inode"

let root_current (root : root) =
  let label = root_label root in
  if not (Fd.is_open root.dir.fd) then
    unsafe label "The directory scope has ended"
  else
    boundary label (fun () ->
        let buf = stat root.dir.fd in
        let* () = verify_id label root.dir.id buf in
        let* () = check_root label buf in
        if not (Int64.equal (L.uid buf) root.uid) then
          unsafe label "The root UID changed"
        else
          Eio.Switch.run (fun sw ->
              let* fd = path_fd ~sw (Eio.Path.( / ) root.fs label) in
              verify_id label root.dir.id (stat fd)))

let open_directory ~sw parent name =
  L.openat ~sw ~mode:0 (L.Fd parent) name directory_flags

let ensure_dir ~sw root parent name label intent =
  let* opened = missing (fun () -> open_directory ~sw parent name) in
  let* opened =
    match (opened, intent) with
    | None, Inspect -> Ok None
    | None, Prepare ->
        (try L.mkdir ~mode:directory_mode (L.Fd parent) name
         with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
        Ok (Some (open_directory ~sw parent name))
    | Some fd, (Prepare | Inspect) -> Ok (Some fd)
  in
  match opened with
  | None -> Ok None
  | Some fd ->
      let buf = stat fd in
      let* () = check_metadata root label Directory buf in
      Ok (Some { fd; id = id buf })

let named_stat parent name =
  let buf = L.create_stat () in
  L.fstatat ~buf ~follow:false (L.Fd parent) name;
  buf

let check_named (root : root) parent name label (expected : handle) kind =
  if not (Fd.is_open expected.fd) then
    unsafe label "The entry's scope has ended"
  else
    let* () = verify_id label expected.id (stat expected.fd) in
    let buf = named_stat parent name in
    let* () = check_metadata root label kind buf in
    verify_id label expected.id buf

let guard_current (guard : key_guard) =
  let* () = root_current guard.root in
  boundary (metadata_label guard) (fun () ->
      let* () =
        check_named guard.root guard.root.dir.fd control_name
          (control_label guard.root) guard.control Directory
      in
      let* () =
        check_named guard.root guard.control.fd
          (Workspace_key.text guard.key)
          (metadata_label guard) guard.metadata Directory
      in
      check_named guard.root guard.metadata.fd lock_name
        (leaf_label guard lock_name)
        guard.lock File)

let open_key ~sw (root : root) key intent =
  let label = Filename.concat (control_label root) (Workspace_key.text key) in
  boundary label (fun () ->
      let* () = root_current root in
      let* control =
        ensure_dir ~sw root root.dir.fd control_name (control_label root) intent
      in
      match control with
      | None -> Ok None
      | Some control -> (
          let* metadata =
            ensure_dir ~sw root control.fd (Workspace_key.text key) label intent
          in
          match metadata with
          | None -> Ok None
          | Some metadata -> (
              let flags =
                match intent with
                | Prepare -> prepare_lock_flags
                | Inspect -> inspect_lock_flags
              in
              let* lock =
                missing (fun () ->
                    L.openat ~sw ~mode:file_mode (L.Fd metadata.fd) lock_name
                      flags)
              in
              match lock with
              | None -> Ok None
              | Some fd -> (
                  let buf = stat fd in
                  let* () =
                    check_metadata root
                      (Filename.concat label lock_name)
                      File buf
                  in
                  let* status =
                    match Workspace_flock.acquire fd with
                    | Ok status -> Ok status
                    | Error error ->
                        filesystem
                          (Filename.concat label lock_name)
                          ("flock: " ^ Unix.error_message error)
                  in
                  match status with
                  | Workspace_flock.Busy ->
                      Error
                        (Workspace_manager.Ownership_conflict
                           (diagnostic label
                              "The workspace key is already leased"
                              "Wait for the owning attempt to release its \
                               lease, then retry."))
                  | Workspace_flock.Acquired ->
                      let guard =
                        {
                          root;
                          key;
                          control;
                          metadata;
                          lock = { fd; id = id buf };
                        }
                      in
                      let* () = guard_current guard in
                      Eio.Fiber.check ();
                      Ok (Some guard)))))

let lookup ~sw (root : root) key =
  let label = key_label root key in
  boundary label (fun () ->
      let* () = root_current root in
      let* fd =
        missing (fun () ->
            open_directory ~sw root.dir.fd (Workspace_key.text key))
      in
      match fd with
      | None -> Ok None
      | Some fd ->
          let dir = handle fd in
          let* () = check_device label root.dir.id.device dir.id.device in
          Ok (Some { root; key; dir }))

let create ~sw (root : root) key =
  let label = key_label root key in
  boundary label (fun () ->
      let* () = root_current root in
      Eio.Fiber.check ();
      Eio.Cancel.protect (fun () ->
          L.mkdir ~mode:directory_mode (L.Fd root.dir.fd)
            (Workspace_key.text key);
          try
            let fd = open_directory ~sw root.dir.fd (Workspace_key.text key) in
            let dir = handle fd in
            let* () = check_device label root.dir.id.device dir.id.device in
            Ok (Fresh { root; key; dir })
          with (Unix.Unix_error _ | Eio.Io _) as error ->
            Error
              (Workspace_manager.Filesystem_error
                 (diagnostic label
                    ("The workspace was created, but opening its directory \
                      failed: " ^ Printexc.to_string error)
                    "Inspect this unowned entry and reconcile or remove it \
                     after confirming its identity, then retry."))))

let directory (Fresh directory) = directory
let identity (directory : directory) = directory.dir.id
let display (directory : directory) = key_label directory.root directory.key

let owner_fd ~sw (guard : key_guard) name flags =
  let* fd =
    missing (fun () ->
        L.openat ~sw ~mode:file_mode (L.Fd guard.metadata.fd) name flags)
  in
  match fd with
  | None -> Ok None
  | Some fd ->
      let* () =
        check_metadata guard.root (leaf_label guard name) File (stat fd)
      in
      Ok (Some fd)

let read_bounded label fd =
  let capacity = Workspace_owner.max_bytes + 1 in
  let bytes = Cstruct.create capacity in
  let rec read used =
    if used = capacity then
      conflict label "The ownership record exceeds its byte limit"
    else
      let count = L.readv fd [| Cstruct.sub bytes used (capacity - used) |] in
      if count = 0 then Ok (Cstruct.to_string (Cstruct.sub bytes 0 used))
      else read (used + count)
  in
  read 0

let read_owner (guard : key_guard) =
  boundary (leaf_label guard owner_name) (fun () ->
      let* () = guard_current guard in
      Eio.Switch.run (fun sw ->
          let* fd = owner_fd ~sw guard owner_name read_flags in
          match fd with
          | None -> Ok None
          | Some fd ->
              Result.map Option.some
                (read_bounded (leaf_label guard owner_name) fd)))

let revalidate (guard : key_guard) (directory : directory) =
  let label = display directory in
  boundary label (fun () ->
      if
        (not (same_id guard.root.dir.id directory.root.dir.id))
        || Workspace_key.compare guard.key directory.key <> 0
      then
        unsafe label
          "The directory and key guard belong to different roots or keys"
      else
        let* () = guard_current guard in
        if not (Fd.is_open directory.dir.fd) then
          unsafe label "The directory scope has ended"
        else
          let* () = verify_id label directory.dir.id (stat directory.dir.fd) in
          let buf =
            named_stat guard.root.dir.fd (Workspace_key.text guard.key)
          in
          let* () = check_kind label Directory buf in
          verify_id label directory.dir.id buf)

let owner_matches (guard : key_guard) (directory : directory) owner =
  let expected = identity directory in
  let* key =
    match Workspace_key.of_identifier (Workspace_owner.identifier owner) with
    | Ok key -> Ok key
    | Error message -> conflict (leaf_label guard owner_name) message
  in
  if
    Workspace_key.compare guard.key key = 0
    && Int64.equal expected.device (Workspace_owner.device owner)
    && Int64.equal expected.inode (Workspace_owner.inode owner)
  then Ok ()
  else
    conflict
      (leaf_label guard owner_name)
      "The ownership record names a different workspace key or inode"

let write_all label fd text =
  let bytes = Cstruct.of_string text in
  let rec write remaining =
    if Cstruct.length remaining = 0 then Ok ()
    else
      let count = L.writev fd [| remaining |] in
      if count = 0 then filesystem label "writev made no progress"
      else write (Cstruct.shift remaining count)
  in
  write bytes

let publish_owner (guard : key_guard) owner =
  let label = leaf_label guard owner_name in
  boundary label (fun () ->
      let* () = guard_current guard in
      Eio.Switch.run (fun sw ->
          let* directory = lookup ~sw guard.root guard.key in
          match directory with
          | None ->
              conflict label "No workspace directory exists for this owner"
          | Some directory ->
              let* () = owner_matches guard directory owner in
              let* pending = owner_fd ~sw guard pending_name read_flags in
              (match pending with
              | None -> ()
              | Some _ ->
                  L.unlink ~dir:false (L.Fd guard.metadata.fd) pending_name);
              let* target = owner_fd ~sw guard owner_name read_flags in
              ignore target;
              let fd =
                L.openat ~sw ~mode:file_mode (L.Fd guard.metadata.fd)
                  pending_name pending_flags
              in
              let* () =
                check_metadata guard.root
                  (leaf_label guard pending_name)
                  File (stat fd)
              in
              let* () =
                write_all
                  (leaf_label guard pending_name)
                  fd
                  (Workspace_owner.encode owner)
              in
              L.fsync fd;
              let* () = revalidate guard directory in
              L.rename (L.Fd guard.metadata.fd) pending_name
                (L.Fd guard.metadata.fd) owner_name;
              Ok ()))

let checked_owner (guard : key_guard) (directory : directory) =
  let* text = read_owner guard in
  match text with
  | None -> Ok None
  | Some text ->
      let* owner =
        match Workspace_owner.parse text with
        | Ok owner -> Ok owner
        | Error message -> conflict (leaf_label guard owner_name) message
      in
      let* () = owner_matches guard directory owner in
      Ok (Some owner)

let clear_owner (guard : key_guard) (directory : directory) =
  let* owner = checked_owner guard directory in
  match owner with
  | None -> Ok ()
  | Some _ ->
      L.unlink ~dir:false (L.Fd guard.metadata.fd) owner_name;
      Ok ()

let valid_entry name =
  name <> "" && name <> "." && name <> ".."
  && (not (String.contains name '/'))
  && not (String.contains name '\000')

let rec remove_entries device depth label parent =
  let entries =
    (* Close each cursor before mutating its entries; width memory stays bounded. *)
    L.with_dir_entries (L.Fd parent) "." (fun entries ->
        entries |> Seq.take removal_batch_size |> List.of_seq)
    |> List.map snd |> List.sort String.compare
  in
  match entries with
  | [] -> Ok ()
  | _ ->
      let* () =
        List.fold_left
          (fun result name ->
            let* () = result in
            if not (valid_entry name) then
              unsafe label "The directory backend returned an unsafe entry name"
            else
              remove_entry device depth (Filename.concat label name) parent name)
          (Ok ()) entries
      in
      remove_entries device depth label parent

and remove_entry device depth label parent name =
  let* buf = missing (fun () -> named_stat parent name) in
  match buf with
  | None -> Ok ()
  | Some buf when L.kind buf <> `Directory ->
      (try L.unlink ~dir:false (L.Fd parent) name
       with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
      Ok ()
  | Some buf ->
      let* () = check_device label device (L.dev buf) in
      if depth >= max_removal_depth then
        (* Untrusted filesystem depth requires one runtime bound before FD loans. *)
        Error
          (Workspace_manager.Filesystem_error
             (diagnostic label "The workspace exceeds the removal depth limit"
                "Reduce this directory's nesting, then retry cleanup."))
      else
        Eio.Switch.run (fun sw ->
            let fd = open_directory ~sw parent name in
            let* () = verify_id label (id buf) (stat fd) in
            let* () = remove_entries device (depth + 1) label fd in
            let* () = verify_id label (id buf) (named_stat parent name) in
            L.unlink ~dir:true (L.Fd parent) name;
            Ok ())

let remove (guard : key_guard) (directory : directory) =
  let label = display directory in
  boundary label (fun () ->
      let* () = guard_current guard in
      if
        (not (same_id guard.root.dir.id directory.root.dir.id))
        || Workspace_key.compare guard.key directory.key <> 0
      then
        unsafe label
          "The directory and key guard belong to different roots or keys"
      else
        let* current =
          missing (fun () ->
              named_stat guard.root.dir.fd (Workspace_key.text guard.key))
        in
        match current with
        | None -> clear_owner guard directory
        | Some _ -> (
            let* () = revalidate guard directory in
            let* owner = checked_owner guard directory in
            match owner with
            | None ->
                conflict
                  (leaf_label guard owner_name)
                  "The workspace has no ownership record"
            | Some _ ->
                let* () =
                  remove_entries guard.root.dir.id.device 0 label
                    directory.dir.fd
                in
                let* () = revalidate guard directory in
                L.unlink ~dir:true (L.Fd guard.root.dir.fd)
                  (Workspace_key.text guard.key);
                clear_owner guard directory))

let discard_unpublished (guard : key_guard) (Fresh directory) =
  let label = display directory in
  let absent_owner () =
    let* owner = read_owner guard in
    match owner with
    | None -> Ok ()
    | Some _ ->
        conflict
          (leaf_label guard owner_name)
          "An ownership record exists; unpublished rollback is not authorized"
  in
  boundary label (fun () ->
      let* () = guard_current guard in
      if
        (not (same_id guard.root.dir.id directory.root.dir.id))
        || Workspace_key.compare guard.key directory.key <> 0
      then
        unsafe label
          "The directory and key guard belong to different roots or keys"
      else
        let* () = absent_owner () in
        let* current =
          missing (fun () ->
              named_stat guard.root.dir.fd (Workspace_key.text guard.key))
        in
        match current with
        | None -> Ok ()
        | Some _ ->
            let* () = revalidate guard directory in
            let* () =
              remove_entries guard.root.dir.id.device 0 label directory.dir.fd
            in
            let* () = revalidate guard directory in
            let* () = absent_owner () in
            L.unlink ~dir:true (L.Fd guard.root.dir.fd)
              (Workspace_key.text guard.key);
            Ok ())

let with_cwd (directory : directory) fn =
  Fd.use_exn "workspace-cwd" directory.dir.fd (fun _ -> fn directory.dir.fd)
