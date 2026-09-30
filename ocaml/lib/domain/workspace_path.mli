(** No pathname parser or constructor. The workspace driver produces this
    capability only after directory acquisition and containment checks. *)

module type S = sig
  type t

  val display : t -> string
  (** Display is informational; it cannot substitute for the capability at
      launch. OCaml cannot encode OS mutation or linear lifetimes. The driver
      owns atomic acquisition, identity checks, launch validation, and
      scope-bound release. *)
end
