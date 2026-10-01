type framing = Fixed | Chunked | Until_eof

let body = String.concat ""

let wire ~status framing chunks =
  let content = body chunks in
  let head, encoded =
    match framing with
    | Fixed ->
        ( Printf.sprintf "Content-Length: %d\r\n" (String.length content),
          content )
    | Chunked ->
        let chunk value =
          if value = "" then ""
          else Printf.sprintf "%x\r\n%s\r\n" (String.length value) value
        in
        ( "Transfer-Encoding: chunked\r\n",
          body (List.map chunk chunks) ^ "0\r\n\r\n" )
    | Until_eof -> ("", content)
  in
  Printf.sprintf "HTTP/1.1 %03d Response\r\n%s\r\n%s" status head encoded

let split ~width value =
  if width <= 0 then None
  else
    let length = String.length value in
    let rec loop offset reversed =
      if offset = length then List.rev reversed
      else
        let count = min width (length - offset) in
        loop (offset + count) (String.sub value offset count :: reversed)
    in
    Some (loop 0 [])
