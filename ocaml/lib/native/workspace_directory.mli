(** Anchored native filesystem mechanism. Store owns the supplied scopes and
    semantic leases; this module never invokes a Store or user callback.
    Workspace directories and recursively visited directories must share the
    root device. Device equality cannot detect same-device bind mounts; these
    remain within the protected parent/cooperating host boundary. *)

type intent = Prepare | Inspect
type root
type key_guard
type directory
type fresh
type identity = { device : int64; inode : int64 }

val open_root :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  sw:Eio.Switch.t ->
  intent ->
  Absolute_path.t ->
  (root option, Workspace_manager.error) result
(** Inspect never creates a missing root. Prepare creates it with restricted
    permissions. Successful roots are nofollow directories without group/world
    write permission; their descriptor and full identity remain scope-owned. *)

val open_key :
  sw:Eio.Switch.t ->
  root ->
  Workspace_key.t ->
  intent ->
  (key_guard option, Workspace_manager.error) result
(** Acquire the permanent actual-key lock beneath [@symphony]. Metadata
    directories are 0700; regular single-link files are 0600 and share the root
    UID. Inspect creates nothing. Separate opens contend, including within one
    process. Final descriptor close releases the lock; lock/key entries are
    never removed. *)

val lookup :
  sw:Eio.Switch.t ->
  root ->
  Workspace_key.t ->
  (directory option, Workspace_manager.error) result
(** Missing lookup changes no entry. Symlinks and non-directories grant no
    authority; a different-device directory grants no authority. A directory
    retains the identity of its opened descriptor. *)

val create :
  sw:Eio.Switch.t ->
  root ->
  Workspace_key.t ->
  (fresh, Workspace_manager.error) result
(** Create exclusively. An existing entry is never adopted by this operation.
    The returned capability permits rollback before owner publication. Minting
    after mkdir is cancellation protected. If opening fails after mkdir, the
    error names the unowned entry for operator reconciliation; no unidentified
    name is deleted. *)

val directory : fresh -> directory
(** Project the exact created directory; this never performs a lookup. *)

val discard_unpublished :
  key_guard -> fresh -> (unit, Workspace_manager.error) result
(** Remove only the freshly created identity while its owner is absent. Any
    ownership record or displaced name rejects rollback. Missing rollback is
    idempotent and never authorizes deletion of a later competing creation. *)

val identity : directory -> identity

val display : directory -> string
(** Observations are immutable: identity is the original full device/inode pair;
    display is the frozen root label joined with the checked key. *)

val read_owner : key_guard -> (string option, Workspace_manager.error) result
(** Read only under the held lock. Reject nonregular, linked, foreign-UID or
    incorrectly permitted metadata and reject byte max_bytes+1 before parsing.
    Missing owner returns None without creation. Store parses the returned
    bytes. *)

val publish_owner :
  key_guard -> Workspace_owner.t -> (unit, Workspace_manager.error) result
(** Publish canonical bounded bytes by same-directory atomic rename. The owner
    identity must match the current workspace. Failure never publishes a partial
    record; a leftover secure pending file may be removed by the next
    publication. *)

val revalidate :
  key_guard -> directory -> (unit, Workspace_manager.error) result
(** Recheck root, control/key/lock and workspace names against retained
    identities. Displacement or ended scopes grant no authority. Store
    separately checks the record's scope, issue ID and original identifier
    against its frozen reference. *)

val remove : key_guard -> directory -> (unit, Workspace_manager.error) result
(** Revalidate and delete through anchored nofollow handles, then clear matching
    ownership metadata. Partial removal retains the owner. Repeated successful
    missing removal preserves the filesystem projection. Final name removal
    relies on the protected parent/cooperating host: POSIX has no conditional
    inode-matching unlink/rmdir. Traversal holds at most 128 entries per level
    and refuses nesting beyond 128 child directories; limit errors retain the
    owner and permit retry after operator correction. Different-device child
    directories are rejected before opening or traversing them. *)

val with_cwd : directory -> (Eio_unix.Fd.t -> 'a) -> 'a
(** Borrow through the complete callback. Callback values/exceptions are
    untouched. Store's Path loan must remain live through child closure; an FD
    reference alone grants no semantic lease. Ended scopes raise
    Invalid_argument. *)
