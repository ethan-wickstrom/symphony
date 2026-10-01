type errors = No_errors | Ordinary_errors | Rate_errors | Invalid_errors
type data = Object_data | Missing_data | Other_data
type envelope = Invalid_json | Valid of errors * data
type response = Accepted | Rate | Status | Malformed

let response ~status envelope =
  match (status, envelope) with
  | 429, _ -> Rate
  | 400, Valid (Rate_errors, _) -> Rate
  | status, _ when status < 200 || status >= 300 -> Status
  | _, Invalid_json -> Malformed
  | _, Valid (Rate_errors, _) -> Rate
  | _, Valid ((Ordinary_errors | Invalid_errors), _) -> Malformed
  | _, Valid (No_errors, Object_data) -> Accepted
  | _, Valid (No_errors, (Missing_data | Other_data)) -> Malformed

type history = string list

let start = []

let advance seen cursor =
  if List.exists (String.equal cursor) seen then None
  else Some (seen @ [ cursor ])

let ordered = List.concat

type completeness = Complete | Incomplete

type blocker =
  | Other
  | Unknown
  | Blocks of { source : string; target : string; state : string option }

let key text = String.lowercase_ascii (String.trim text)

let dispatchable ~id ~state ~terminal completeness blockers =
  if key state <> "todo" then true
  else
    match completeness with
    | Incomplete -> false
    | Complete ->
        List.for_all
          (function
            | Other -> true
            | Unknown -> false
            | Blocks { source; target; state } -> (
                source <> id && target = id
                &&
                match state with
                | None -> false
                | Some state ->
                    List.exists (fun t -> key t = key state) terminal))
          blockers

let labels texts =
  (* The Issue contract exposes unique labels, with a canonical set projection;
     label order is independent of provider issue/page order. *)
  List.fold_left
    (fun found text ->
      let normalized = key text in
      if
        normalized = ""
        || String.contains normalized '\000'
        || List.exists (String.equal normalized) found
      then found
      else found @ [ normalized ])
    [] texts
  |> List.sort String.compare

type decimal = { mantissa : int; scale : int; exponent : int }

let maximum_mantissa = 1_000_000
let maximum_scale = 6
let maximum_exponent = 25

let decimal ~mantissa ~scale ~exponent =
  if
    mantissa < -maximum_mantissa
    || mantissa > maximum_mantissa
    || scale < 0 || scale > maximum_scale
    || exponent < -maximum_exponent
    || exponent > maximum_exponent
  then None
  else Some { mantissa; scale; exponent }

let lexeme { mantissa; scale; exponent } =
  let digits = string_of_int (abs mantissa) in
  let padding = max 0 (scale + 1 - String.length digits) in
  let digits = String.make padding '0' ^ digits in
  let split = String.length digits - scale in
  let whole = String.sub digits 0 split in
  let fraction =
    if scale = 0 then "" else "." ^ String.sub digits split scale
  in
  let sign = if mantissa < 0 then "-" else "" in
  sign ^ whole ^ fraction ^ "e" ^ string_of_int exponent

let integer { mantissa; scale; exponent } =
  let ten = Z.of_int 10 in
  let power = exponent - scale in
  let numerator, denominator =
    if power >= 0 then (Z.mul (Z.of_int mantissa) (Z.pow ten power), Z.one)
    else (Z.of_int mantissa, Z.pow ten (-power))
  in
  let quotient, remainder = Z.div_rem numerator denominator in
  if Z.equal remainder Z.zero && Z.fits_int quotient then
    Some (Z.to_int quotient)
  else None
