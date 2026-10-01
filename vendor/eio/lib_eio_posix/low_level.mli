(** This module provides an effects-based API for calling POSIX functions.

    Normally it's better to use the cross-platform {!Eio} APIs instead,
    which uses these functions automatically where appropriate.

    These functions mostly copy the POSIX APIs directly, except that:

    + They suspend the calling fiber instead of returning [EAGAIN] or similar.
    + They handle [EINTR] by automatically restarting the call.
    + They wrap {!Unix.file_descr} in {!Fd}, to avoid use-after-close bugs.
    + They attach new FDs to switches, to avoid resource leaks. *)

open Eio.Std

type fd := Eio_unix.Fd.t

type dir_fd =
  | Fd of fd    (** Confined to [fd]. *)
  | Cwd         (** Confined to "." *)
  | Fs          (** Unconfined "."; also allows absolute paths *)

val await_readable : string -> fd -> unit
val await_writable : string -> fd -> unit

val sleep_until : Mtime.t -> unit

val read : fd -> bytes -> int -> int -> int
val write : fd -> bytes -> int -> int -> int

val socket : sw:Switch.t -> Unix.socket_domain -> Unix.socket_type -> int -> fd
val connect : fd -> Unix.sockaddr -> unit
val accept : sw:Switch.t -> fd -> fd * Unix.sockaddr

val shutdown : fd -> Unix.shutdown_command -> unit

val recv_msg : fd -> Cstruct.t array -> Unix.sockaddr * int
val recv_msg_with_fds : sw:Switch.t -> max_fds:int -> fd -> Cstruct.t array -> Unix.sockaddr * int * fd list

val send_msg : fd -> ?fds:fd list -> ?dst:Unix.sockaddr -> Cstruct.t array -> int

val getrandom : Cstruct.t -> unit

val lseek : fd -> Optint.Int63.t -> [`Set | `Cur | `End] -> Optint.Int63.t
val fsync : fd -> unit
val ftruncate : fd -> Optint.Int63.t -> unit

type stat

val create_stat : unit -> stat

val fstat : buf:stat -> fd -> unit
val fstatat : buf:stat -> follow:bool -> dir_fd -> string -> unit

external blksize : stat -> (int64 [@unboxed]) = "ocaml_eio_posix_stat_blksize_bytes" "ocaml_eio_posix_stat_blksize_native" [@@noalloc]
external blocks  : stat -> (int64 [@unboxed]) = "ocaml_eio_posix_stat_blocks_bytes" "ocaml_eio_posix_stat_blocks_native" [@@noalloc]
external nlink   : stat -> (int64 [@unboxed]) = "ocaml_eio_posix_stat_nlink_bytes" "ocaml_eio_posix_stat_nlink_native" [@@noalloc]
external uid     : stat -> (int64 [@unboxed]) = "ocaml_eio_posix_stat_uid_bytes" "ocaml_eio_posix_stat_uid_native" [@@noalloc]
external gid     : stat -> (int64 [@unboxed]) = "ocaml_eio_posix_stat_gid_bytes" "ocaml_eio_posix_stat_gid_native" [@@noalloc]
external ino     : stat -> (int64 [@unboxed]) = "ocaml_eio_posix_stat_ino_bytes" "ocaml_eio_posix_stat_ino_native" [@@noalloc]
external size    : stat -> (int64 [@unboxed]) = "ocaml_eio_posix_stat_size_bytes" "ocaml_eio_posix_stat_size_native" [@@noalloc]
external rdev    : stat -> (int64 [@unboxed]) = "ocaml_eio_posix_stat_rdev_bytes" "ocaml_eio_posix_stat_rdev_native" [@@noalloc]
external dev     : stat -> (int64 [@unboxed]) = "ocaml_eio_posix_stat_dev_bytes" "ocaml_eio_posix_stat_dev_native" [@@noalloc]
external perm    : stat -> (int [@untagged]) = "ocaml_eio_posix_stat_perm_bytes" "ocaml_eio_posix_stat_perm_native" [@@noalloc]
external mode    : stat -> (int [@untagged]) = "ocaml_eio_posix_stat_mode_bytes" "ocaml_eio_posix_stat_mode_native" [@@noalloc]
external kind    : stat -> Eio.File.Stat.kind = "ocaml_eio_posix_stat_kind"

external atime_sec : stat -> (int64 [@unboxed]) = "ocaml_eio_posix_stat_atime_sec_bytes" "ocaml_eio_posix_stat_atime_sec_native" [@@noalloc]
external ctime_sec : stat -> (int64 [@unboxed]) = "ocaml_eio_posix_stat_ctime_sec_bytes" "ocaml_eio_posix_stat_ctime_sec_native" [@@noalloc]
external mtime_sec : stat -> (int64 [@unboxed]) = "ocaml_eio_posix_stat_mtime_sec_bytes" "ocaml_eio_posix_stat_mtime_sec_native" [@@noalloc]

external atime_nsec : stat -> int = "ocaml_eio_posix_stat_atime_nsec" [@@noalloc]
external ctime_nsec : stat -> int = "ocaml_eio_posix_stat_ctime_nsec" [@@noalloc]
external mtime_nsec : stat -> int = "ocaml_eio_posix_stat_mtime_nsec" [@@noalloc]

val realpath : string -> string
val read_link : dir_fd -> string -> string

val mkdir : mode:int -> dir_fd -> string -> unit
val unlink : dir:bool -> dir_fd -> string -> unit
val rename : dir_fd -> string -> dir_fd -> string -> unit

val symlink : link_to:string -> dir_fd -> string -> unit
(** [symlink ~link_to dir path] will create a new symlink at [dir / path]
    linking to [link_to]. *)

val chmod : follow:bool -> mode:int -> dir_fd -> string -> unit

val chown : follow:bool -> ?uid:int64 -> ?gid:int64 -> dir_fd -> string -> unit
(** [chown ~follow ~uid ~gid dir path] will change the ownership of [dir / path]
    to [uid, gid]. *)

val readdir : dir_fd -> string -> string array
val with_dir_entries : dir_fd -> string -> ((Eio.File.Stat.kind * string) Seq.t -> 'a) -> 'a

val readv : fd -> Cstruct.t array -> int
val writev : fd -> Cstruct.t array -> int

val preadv : file_offset:Optint.Int63.t -> fd -> Cstruct.t array -> int
val pwritev : file_offset:Optint.Int63.t -> fd -> Cstruct.t array -> int

val pipe : sw:Switch.t -> fd * fd

module Open_flags : sig
  type t

  val rdonly : t
  val rdwr : t
  val wronly : t
  val append : t
  val creat : t
  val directory : t
  val dsync : t option
  val excl : t
  val noctty : t
  val nofollow : t
  val sync : t
  val trunc : t
  val resolve_beneath : t option
  val path : t option

  val empty : t
  val ( + ) : t -> t -> t
  val ( +? ) : t -> t option -> t       (** Add if available *)
end

val openat : sw:Switch.t -> mode:int -> dir_fd -> string -> Open_flags.t -> fd
(** Note: the returned FD is always non-blocking and close-on-exec. *)

module Process : sig
  type t
  (** A child process. *)

  module Fork_action = Eio_unix.Private.Fork_action
  (** Setup actions to perform in the child process. *)

  val spawn : sw:Switch.t -> Fork_action.t list -> t
  (** [spawn ~sw actions] forks a child process, which executes [actions].
      The last action should be {!Fork_action.execve}.

      You will typically want to do [Promise.await (exit_status child)] after this.

      @param sw The child will be sent {!Sys.sigkill} if [sw] finishes. *)

  val signal : t -> int -> unit
  (** [signal t x] sends signal [x] to [t].

      This is similar to doing [Unix.kill t.pid x],
      except that it ensures no signal is sent after [t] has been reaped. *)

  val pid : t -> int

  val exit_status : t -> Unix.process_status Promise.t
  (** [exit_status t] is a promise for the process's exit status. *)

  module Group : sig
    type t
    (** Switch-owned custody of a private process group. Numeric identity and
        reaping authority never leave this module. *)

    type exit = Exited of int | Signaled of int
    type signal = Term | Kill
    type cleanup_cause =
      | Group_signal of Unix.error
      | Leader_signal of Unix.error
      | Reap of Unix.error
    type cleanup_error = cleanup_cause * cleanup_cause list
    type spawn_error = Spawn_error of Unix.error | Worker_unavailable of string
                     | Spawn_cleanup_failed of Unix.error * cleanup_error
    (** Nonempty causes in execution order: final group signal, leader signal,
        and reap. Cancellation initiates this same final cleanup. *)

    val spawn :
      sw:Switch.t -> cwd:fd -> stdin:fd -> stdout:fd -> stderr:fd ->
      executable:string -> argv:string array -> env:string array ->
      report_cleanup:(cleanup_error -> unit) -> (t, spawn_error) result
    (** Establish the child's own process group, enter [cwd] using its
        descriptor, map exactly stdin/stdout/stderr as blocking descriptors,
        then execute the argument array. Callers cannot reorder these actions.
        Descriptor ownership stays with their switches; the child gets duplicates.
        [report_cleanup] observes each failed cleanup exactly once, outside the
        native worker and mutex. Expected sink failures must be handled inside
        the sink. Automatic release retains a sink defect with its backtrace
        without replacing the caller's primary outcome. Public close surfaces
        the retained defect after checking cancellation.

        Law: successful spawn grants exactly one custody scope. Observing exit
        retains its leader unreaped; switch release sends group KILL before
        exactly one reap. Expected cleanup errors are retained as values, and
        switch release cannot replace the caller's outcome with those errors.
        Reaping revokes signaling and observation before the
        kernel releases the PID; repeated cleanup shares one stable completion.
        The blocking reap holds no scheduler mutex. No recycled ID is signaled.
        No OCaml code runs between fork and exec.
        One blocking Eio system-thread job is reserved before fork and owns both
        observation and final reap; cleanup allocates no additional worker.
        A simulator can supply its own agent driver without native jobs.

        Host fork/exec errors and worker-admission failures are values. A failed
        admission performs no fork. Raises [Cancel.Cancelled] on cancellation
        after cleanup, and defects with their original backtrace.
        Kernel exit/reaping liveness has no finite POSIX deadline. *)

    val await_exit : t -> (exit, Unix.error) result
    (** Observe terminal leader status without relinquishing custody.
        Law: repeated successful observations return the same status and never
        reap. Cancelable; raises [Cancel.Cancelled] on caller cancellation.
        Observation is independent of SIGCHLD delivery. Cleanup grants sole reap
        authority to the already-reserved producer and joins its completion.
        Host observation/reap failures are values; defects remain exceptions. *)

    val signal : t -> signal -> (unit, Unix.error) result
    (** Signal the owned group while its leader's PID remains reserved.
        Law: repeated KILL preserves custody and is safe; signaling after release
        or a nonexistent original group is a no-op. Darwin's zombie-only EPERM
        is accepted only when a bounded group snapshot has no live member;
        uncertainty and query failure preserve [Error EPERM]. Other host failures
        are error values. Cancellation cannot split the check and syscall.
        Descendants that leave the group are outside this guarantee. Release
        also signals the direct child if it moved to another group. *)

    val close : t -> (unit, cleanup_error) result
    (** Initiate or join the one protected cleanup and observe its stored result.
        Law: repeated completed cleanup returns the same nonempty error or
        success, never signals a recycled ID, and never performs another reap.
        Each cleanup stage runs even if an earlier stage fails; every expected
        failure is retained. Group KILL is swept again after earlier requests.
        Calling [close] before returning makes release errors observable.
        Cancellation waits for cleanup, then raises [Cancel.Cancelled]; switch
        release uses the same protected completion without raising expected
        failures. No finite kernel reaping deadline is promised. *)
  end
end

(**/**)
(* Exposed for testing only. *)
module Resolve : sig
  val open_beneath_fallback : ?dirfd:Unix.file_descr -> sw:Switch.t -> mode:int -> string -> Open_flags.t -> fd
  val open_unconfined : sw:Switch.t -> mode:int -> fd option -> string -> Open_flags.t -> fd
end
(**/**)
