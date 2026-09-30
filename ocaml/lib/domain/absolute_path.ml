type t = string

let parse s =
  if not (String.starts_with ~prefix:"/" s) then
    Error "expected an absolute path"
  else if String.contains s '\000' || not (Text.valid_utf8 s) then
    Error "path contains NUL or invalid UTF-8"
  else
    let parts =
      List.fold_left
        (fun acc -> function
          | "" | "." -> acc
          | ".." -> (
              match acc with
              | [] -> []
              | _ :: rest -> rest)
          | part -> part :: acc)
        []
        (String.split_on_char '/' s)
    in
    Ok ("/" ^ String.concat "/" (List.rev parts))

let display x = x
