module F = Service_failure

exception Callback_defect of int

type observation = Success | Error | Defect

let model values =
  List.find_map
    (function
      | Success -> None
      | (Error | Defect) as failure -> Some failure)
    values

let agrees observations =
  let register = F.create () in
  let diagnostic = Core_fixture.diagnostic in
  let original = Callback_defect 41 in
  let backtrace = Printexc.get_callstack 8 in
  List.iter
    (fun observation ->
      F.record register ()
        (match observation with
        | Success -> F.Returned (Ok ())
        | Error -> F.Returned (Error diagnostic)
        | Defect -> F.Raised (original, backtrace)))
    observations;
  match (model observations, F.prefer register (F.Returned (Ok ()))) with
  | None, F.Returned (Ok ()) -> not (F.failed register)
  | Some Error, F.Returned (Error actual) -> actual == diagnostic
  | Some Defect, F.Raised (actual, trace) ->
      actual == original && trace == backtrace
  | ( (None | Some (Success | Error | Defect)),
      (F.Returned (Ok () | Error _) | F.Raised _) ) -> false

let properties =
  let open QCheck2 in
  [
    Test.make ~name:"failure register equals first unsuccessful observation"
      ~count:1000
      (Gen.list_size (Gen.int_range 0 100)
         (Gen.oneof_list [ Success; Error; Defect ]))
      agrees;
  ]
