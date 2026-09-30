type t = Absolute_path.t

let resolve ~base s =
  if String.trim s = "" then Error "workflow filename must be nonempty"
  else
    let path =
      if Filename.is_relative s then
        Filename.concat (Absolute_path.display base) s
      else s
    in
    Absolute_path.parse path

let absolute x = x
let display = Absolute_path.display
