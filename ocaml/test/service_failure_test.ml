module F = Service_failure

exception Callback_defect of int

type observation = Success | Error | Defect

let model entries =
  List.find_map
    (function
      | Success, _ -> None
      | (Error | Defect), outcome -> Some outcome)
    entries

let agrees observations =
  let register = F.create () in
  (* Distinct identities make replacing the first Error with a later Error
     observable, even when both failures have the same constructor. *)
  let entries =
    List.mapi
      (fun index observation ->
        let outcome =
          match observation with
          | Success -> F.Returned (Ok ())
          | Error ->
              F.Returned
                (Error
                   (Diagnostic.make ~site:(Diagnostic.Host "failure model")
                      ~message:("observation " ^ string_of_int index)
                      ~remedy:"Retain the first failed observation."))
          | Defect -> F.Raised (Callback_defect index, Printexc.get_callstack 8)
        in
        (observation, outcome))
      observations
  in
  List.iter (fun (_, outcome) -> F.record register () outcome) entries;
  match (model entries, F.prefer register (F.Returned (Ok ()))) with
  | None, F.Returned (Ok ()) -> not (F.failed register)
  | Some (F.Returned (Error expected)), F.Returned (Error actual) ->
      actual == expected
  | Some (F.Raised (expected, origin)), F.Raised (actual, trace) ->
      actual == expected && trace == origin
  | ( (None | Some (F.Returned (Ok () | Error _) | F.Raised _)),
      (F.Returned (Ok () | Error _) | F.Raised _) ) -> false

let properties =
  let open QCheck2 in
  [
    Test.make ~name:"failure register equals first unsuccessful observation"
      ~count:1000
      ~print:(fun observations ->
        String.concat ","
          (List.map
             (function
               | Success -> "success"
               | Error -> "error"
               | Defect -> "defect")
             observations))
      (Gen.list_size (Gen.int_range 0 100)
         (Gen.oneof_list [ Success; Error; Defect ]))
      agrees;
  ]
