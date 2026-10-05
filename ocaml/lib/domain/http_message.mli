(** Plain HTTP boundary values. They carry no transport or service authority. *)

type method_ = Get | Post | Other of string
type request = { method_ : method_; path : string; body : string }

type response = {
  status : int;
  content_type : string;
  body : string;
  allow : method_ list;
      (** Supported methods for a 405 response; empty for every other status.
          The transport checks this invariant before serialization. *)
}
