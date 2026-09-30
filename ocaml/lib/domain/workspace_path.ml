module type S = sig
  type t

  val display : t -> string
end
