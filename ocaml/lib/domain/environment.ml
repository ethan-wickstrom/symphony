module Names = Map.Make (String)

type t = { vars : string Names.t; temp_dir : Absolute_path.t }
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

let lookup e k = Names.find_opt k e.vars
let temp_dir e = e.temp_dir

let child e ~allow ~deny =
  Names.bindings e.vars
  |> List.filter (fun (k, _) -> List.mem k allow && not (List.mem k deny))

let bindings x = x
