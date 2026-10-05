type method_ = Get | Post | Other of string
type request = { method_ : method_; path : string; body : string }

type response = {
  status : int;
  content_type : string;
  body : string;
  allow : method_ list;
}
