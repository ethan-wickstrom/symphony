module type S = sig
  type t

  val parse : string -> (t, string) result
  val text : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int

  module Order : Map.OrderedType with type t = t
  module Map : Map.S with type key = t
  module Set : Set.S with type elt = t
end

module Make () = struct
  type t = string

  let parse s =
    if String.trim s = "" then Error "identity must be nonempty"
    else if String.contains s '\000' || not (Text.valid_utf8 s) then
      Error "identity contains NUL or invalid UTF-8"
    else Ok s

  let text x = x
  let equal = String.equal
  let compare = String.compare

  module Order = struct
    type nonrec t = t

    let compare = compare
  end

  module Map = Map.Make (Order)
  module Set = Set.Make (Order)
end
