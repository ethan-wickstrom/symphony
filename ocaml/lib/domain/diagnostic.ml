type site =
  | Workflow of { file : string; key : string option; line : int option }
  | Issue of { id : Issue_id.t; identifier : Issue_identifier.t }
  | Protocol of { method_name : string; request_id : string option }
  | Host of string

type t = { site : site; message : string; remedy : string }

let make ~site ~message ~remedy = { site; message; remedy }
let site x = x.site

let render x =
  let place =
    match x.site with
    | Workflow { file; key; line } ->
        file
        ^ Option.fold ~none:"" ~some:(fun n -> ":" ^ string_of_int n) line
        ^ Option.fold ~none:"" ~some:(fun k -> " key=" ^ k) key
    | Issue { id; identifier } ->
        "issue_id=" ^ Issue_id.text id ^ " issue_identifier="
        ^ Issue_identifier.text identifier
    | Protocol { method_name; request_id } ->
        method_name
        ^ Option.fold ~none:"" ~some:(fun id -> " request_id=" ^ id) request_id
    | Host s -> s
  in
  Text.escape (place ^ ": " ^ x.message ^ "; " ^ x.remedy)

let at_file file x =
  match x.site with
  | Workflow w -> { x with site = Workflow { w with file } }
  | Issue _ | Protocol _ | Host _ -> x
