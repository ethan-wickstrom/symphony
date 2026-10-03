type failure = Oversized | Invalid_json | Truncated
type observation = { frames : Json.t list; failure : failure option }

let observe ~max_bytes input =
  let result frames failure = { frames = List.rev frames; failure } in
  let rec lines frames = function
    | [] -> result frames None
    | [ residual ] ->
        if String.length residual > max_bytes then
          result frames (Some Oversized)
        else if residual = "" then result frames None
        else result frames (Some Truncated)
    | line :: rest -> (
        if String.length line > max_bytes then result frames (Some Oversized)
        else
          match Json.parse line with
          | Error _ -> result frames (Some Invalid_json)
          | Ok frame -> lines (frame :: frames) rest)
  in
  lines [] (String.split_on_char '\n' input)
