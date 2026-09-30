module Names = Set.Make (String)
module Limits = Map.Make (String)

type stall = Disabled | Silence_limit of Milliseconds.t

type t = {
  active : Names.t;
  terminal : Names.t;
  labels : Names.t;
  poll : Milliseconds.t;
  global : int;
  limits : int Limits.t;
  retry : Milliseconds.t;
  stall : stall;
}

let ( let* ) = Result.bind

let parse ~env config =
  let field keys default parse =
    match Fields.get config keys with
    | None -> Ok default
    | Some v ->
        Result.map_error
          (fun e ->
            Nonempty_list.singleton
              (Fields.diagnostic ~key:(String.concat "." keys) e))
          (parse v)
  in
  let duration keys default =
    let* default =
      Result.map_error
        (fun e ->
          Nonempty_list.singleton
            (Fields.diagnostic ~key:(String.concat "." keys) e))
        (Milliseconds.parse default)
    in
    field keys default (fun v ->
        let* n = Fields.integer env v in
        if Z.sign n <= 0 then Error "duration must be positive"
        else Milliseconds.parse (Z.to_string n))
  in
  let names key =
    match Fields.get config [ "tracker"; key ] with
    | None ->
        Error
          (Nonempty_list.singleton
             (Fields.diagnostic ~key:("tracker." ^ key)
                "explicit state list is required"))
    | Some v ->
        let* xs =
          Result.map_error
            (fun e ->
              Nonempty_list.singleton
                (Fields.diagnostic ~key:("tracker." ^ key) e))
            (Fields.strings env v)
        in
        let xs = List.map Text.normalize xs in
        if List.exists (( = ) "") xs then
          Error
            (Nonempty_list.singleton
               (Fields.diagnostic ~key:("tracker." ^ key)
                  "state names must be nonempty"))
        else Ok (Names.of_list xs)
  in
  let* active = names "active_states" in
  let* terminal = names "terminal_states" in
  if not (Names.is_empty (Names.inter active terminal)) then
    Error
      (Nonempty_list.singleton
         (Fields.diagnostic ~key:"tracker.terminal_states"
            "active and terminal states overlap"))
  else
    let* labels =
      field [ "tracker"; "required_labels" ] Names.empty (fun v ->
          Result.map
            (fun xs -> Names.of_list (List.map Text.normalize xs))
            (Fields.strings env v))
    in
    let* poll = duration [ "polling"; "interval_ms" ] "30000" in
    let* retry = duration [ "agent"; "max_retry_backoff_ms" ] "300000" in
    let* global =
      field [ "agent"; "max_concurrent_agents" ] 10 (fun v ->
          let* n = Fields.integer env v in
          if Z.sign n <= 0 || not (Z.fits_int n) then
            Error "concurrency must be a positive machine integer"
          else Ok (Z.to_int n))
    in
    let* limits =
      field [ "agent"; "max_concurrent_agents_by_state" ] Limits.empty (fun v ->
          let* entries = Fields.mapping v in
          let rec add limits = function
            | [] -> Ok limits
            | (name, v) :: rest -> (
                let key = Text.normalize name in
                match Fields.integer env v with
                | Error _ -> add limits rest
                | Ok n when Z.sign n <= 0 || (not (Z.fits_int n)) || key = "" ->
                    add limits rest
                | Ok n ->
                    if Limits.mem key limits then
                      Error "normalized per-state limits collide"
                    else add (Limits.add key (Z.to_int n) limits) rest)
          in
          add Limits.empty entries)
    in
    let* stall =
      field
        [ "codex"; "stall_timeout_ms" ]
        (Z.of_int 300000) (Fields.integer env)
    in
    let* stall =
      if Z.sign stall <= 0 then Ok Disabled
      else
        Result.map
          (fun ms -> Silence_limit ms)
          (Result.map_error
             (fun e ->
               Nonempty_list.singleton
                 (Fields.diagnostic ~key:"codex.stall_timeout_ms" e))
             (Milliseconds.parse (Z.to_string stall)))
    in
    Ok { active; terminal; labels; poll; global; limits; retry; stall }

let active t = t.active
let terminal t = t.terminal
let required_labels t = t.labels
let poll_interval t = t.poll
let global_limit t = t.global

let state_limit t name =
  Option.value ~default:t.global
    (Limits.find_opt (Text.normalize name) t.limits)

let max_retry_delay t = t.retry
let stall t = t.stall

type state_class = Active | Terminal | Inactive

let classify t issue =
  let key = Issue.state_key issue in
  if Names.mem key t.active then Active
  else if Names.mem key t.terminal then Terminal
  else Inactive

let equal a b = a = b
