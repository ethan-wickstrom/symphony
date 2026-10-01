module Names = Map.Make (String)
module Sources = Set.Make (String)
module Values = Set.Make (String)

module Secret = struct
  type t = string

  let make value = if value = "" then None else Some value
  let equal = String.equal
  let redacted _ = "<redacted>"
end

type t = { vars : string Names.t; temp_dir : Absolute_path.t }

let credential_error =
  "value selects a quarantined credential; use a public value or variable"

module Quarantine = struct
  type t = { denied : Sources.t; values : Values.t; json : Json.t list }

  let check rules value =
    if Values.mem value rules.values then Error credential_error else Ok value

  let rec each inspect = function
    | [] -> Ok ()
    | value :: rest -> Result.bind (inspect value) (fun () -> each inspect rest)

  let check_json rules value =
    let rec inspect value =
      if List.exists (Json.equal value) rules.json then Error credential_error
      else
        match Json.view value with
        | Json.Null | Json.Bool _ -> Ok ()
        | Json.Number value | Json.String value ->
            Result.map (fun _ -> ()) (check rules value)
        | Json.Array children -> each inspect children
        | Json.Object fields ->
            each
              (fun (key, value) ->
                Result.bind (check rules key) (fun _ -> inspect value))
              fields
    in
    Result.map (fun () -> value) (inspect value)

  let equal a b =
    Sources.equal a.denied b.denied && Values.equal a.values b.values
end

type public = {
  vars : string Names.t;
  temp_dir : Absolute_path.t;
  rules : Quarantine.t;
}

type child = (string * string) list

let valid_name s =
  let first = function
    | 'a' .. 'z' | 'A' .. 'Z' | '_' -> true
    | _ -> false
  in
  let later c = first c || (c >= '0' && c <= '9') in
  s <> "" && first s.[0] && String.for_all later s

let of_bindings ~temp_dir entries =
  let rec loop vars = function
    | [] -> Ok { vars; temp_dir }
    | (k, v) :: rest ->
        if
          (not (valid_name k))
          || String.contains v '\000'
          || not (Text.valid_utf8 v)
        then Error "invalid environment name or value"
        else if Names.mem k vars then Error ("duplicate environment name: " ^ k)
        else loop (Names.add k v vars) rest
  in
  loop Names.empty entries

let lookup (e : t) k = Names.find_opt k e.vars
let temp_dir (e : t) = e.temp_dir

let public env ~deny ~secrets =
  let denied = Sources.of_list deny in
  let values =
    Sources.fold
      (fun name values ->
        match lookup env name with
        | Some value when value <> "" -> Values.add value values
        | None | Some _ -> values)
      denied (Values.of_list secrets)
  in
  let json =
    Values.fold
      (fun value parsed ->
        match Json.parse value with
        | Ok value -> value :: parsed
        | Error _ -> parsed)
      values []
  in
  (* Drop raw bindings once, retaining only redacted rejection metadata. *)
  let denied =
    Names.fold
      (fun name value denied ->
        if Values.mem value values then Sources.add name denied else denied)
      env.vars denied
  in
  let vars =
    Names.filter (fun name _ -> not (Sources.mem name denied)) env.vars
  in
  { vars; temp_dir = env.temp_dir; rules = Quarantine.{ denied; values; json } }

let quarantine env = env.rules
let check env value = Quarantine.check env.rules value
let check_json env value = Quarantine.check_json env.rules value

let lookup_public env name =
  if Sources.mem name env.rules.Quarantine.denied then Error credential_error
  else Result.bind (check env name) (fun _ -> Ok (Names.find_opt name env.vars))

let public_temp_dir (env : public) =
  Result.map
    (fun _ -> env.temp_dir)
    (check env (Absolute_path.display env.temp_dir))

let child (env : public) ~allow =
  let allowed = Sources.of_list allow in
  Names.bindings env.vars
  |> List.filter (fun (name, _) -> Sources.mem name allowed)

let bindings x = x
