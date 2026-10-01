(** Bounded ownership records kept outside agent-writable directories. A record
    binds a tracker issue to one acquired directory identity, never a pathname.
    The directory driver reads and writes it only under the persistent key lock.
*)

type t

val max_bytes : int
(** 16,384-byte encoded record limit. The reader must reject an extra byte
    before parsing. Successful [encode] results never exceed this limit. *)

val make :
  scope:Tracker_scope.t ->
  issue_id:Issue_id.t ->
  identifier:Issue_identifier.t ->
  device:int64 ->
  inode:int64 ->
  (t, string) result
(** Checked owner plus exact OS identity bits. Reject an invalid workspace key
    or an oversized encoding. This constructor confers no directory authority.
*)

val parse : string -> (t, string) result
(** Strict JSON with exactly version, scope, issue_id, identifier, device and
    inode. Version is the numeric token [1]; device/inode are exactly 16
    lowercase hex digits representing all int64 bits. Reject duplicates, unsafe
    identities and oversized input. Expected failures are values. *)

val encode : t -> string
(** [parse (encode owner) = Ok owner] under [equal]. Encoding is canonical;
    [encode] after successful parse is idempotent. *)

val equal : t -> t -> bool
(** Equivalence relation. Equals conjunction of scope, opaque issue ID, original
    identifier, device and inode equality. Changing any component breaks
    equality even when the derived filesystem key is unchanged. *)

val scope : t -> Tracker_scope.t
val issue_id : t -> Issue_id.t
val identifier : t -> Issue_identifier.t
val device : t -> int64

val inode : t -> int64
(** Observers reproduce constructor inputs exactly, including all identity bits.
*)
