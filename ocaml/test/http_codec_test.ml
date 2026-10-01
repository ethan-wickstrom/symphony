module Model = Http_codec_model

type reading =
  | Awaiting
  | Receiving of int
  | Finished of int
  | Rejected of string
  | Defect of exn

type outcome =
  | Accepted of int * string
  | Invalid of string
  | Raised of exn
  | Incomplete

type ending = Input_open | Input_end

(* Observe only the public connection API, including its final parser error.
   A body EOF callback cannot independently establish a successful response. *)
let decode_until ending fragments =
  let reading = ref Awaiting in
  let chunks = ref [] in
  let response_handler response reader =
    let status = H1.Status.to_code response.H1.Response.status in
    reading := Receiving status;
    let rec schedule () =
      H1.Body.Reader.schedule_read reader
        ~on_eof:(fun () ->
          match !reading with
          | Receiving value -> reading := Finished value
          | Awaiting | Finished _ | Rejected _ | Defect _ -> ())
        ~on_read:(fun bytes ~off ~len ->
          chunks := Bstr.sub_string bytes ~off ~len :: !chunks;
          schedule ())
    in
    schedule ()
  in
  let error_handler = function
    | `Malformed_response reason -> reading := Rejected reason
    | `Invalid_response_body_length _ ->
        reading := Rejected "invalid response body length"
    | `Exn exn -> reading := Defect exn
  in
  let writer, connection =
    H1.Client_connection.request
      (H1.Request.create `GET "/")
      ~error_handler ~response_handler
  in
  H1.Body.Writer.close writer;
  let pending = ref "" in
  let observe () = H1.Client_connection.next_read_operation connection in
  let feed fragment =
    pending := !pending ^ fragment;
    match observe () with
    | `Close -> ()
    | `Read ->
        let length = String.length !pending in
        let consumed =
          H1.Client_connection.read connection (Bstr.of_string !pending) ~off:0
            ~len:length
        in
        pending := String.sub !pending consumed (length - consumed);
        ignore (observe ())
  in
  try
    List.iter feed fragments;
    (match (ending, observe ()) with
    | Input_open, (`Close | `Read) | Input_end, `Close -> ()
    | Input_end, `Read ->
        ignore
          (H1.Client_connection.read_eof connection (Bstr.of_string !pending)
             ~off:0 ~len:(String.length !pending)));
    ignore (observe ());
    match !reading with
    | Finished status -> Accepted (status, Model.body (List.rev !chunks))
    | Receiving _ | Awaiting -> Incomplete
    | Rejected reason -> Invalid reason
    | Defect exn -> Raised exn
  with exn -> Raised exn

let decode = decode_until Input_end

let show = function
  | Accepted (status, body) -> Printf.sprintf "Accepted (%d, %S)" status body
  | Invalid reason -> "Invalid: " ^ reason
  | Raised exn -> "Raised: " ^ Printexc.to_string exn
  | Incomplete -> "Incomplete without a typed codec error"

let accepted ~status ~body actual =
  match actual with
  | Accepted (got_status, got_body) ->
      Alcotest.(check int) "status" status got_status;
      Alcotest.(check string) "body" body got_body
  | Invalid _ | Raised _ | Incomplete -> Alcotest.fail (show actual)

let invalid actual =
  match actual with
  | Invalid _ -> ()
  | Accepted _ | Raised _ | Incomplete -> Alcotest.fail (show actual)

let chunks_header = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"

let signed_chunk () =
  List.iter
    (fun size ->
      invalid (decode_until Input_open [ chunks_header ^ size ^ "\r\n" ]))
    [ "8000000000000000"; "ffffffffffffffff"; "10000000000000000" ]

let malformed_status () =
  List.iter
    (fun status ->
      invalid
        (decode
           [ "HTTP/1.1 " ^ status ^ " Status\r\nContent-Length: 0\r\n\r\n" ]))
    [ "9"; "00"; "2000"; "wat" ]

let out_of_range_status () =
  List.iter
    (fun status ->
      invalid
        (decode
           [ "HTTP/1.1 " ^ status ^ " Status\r\nContent-Length: 0\r\n\r\n" ]))
    [ "600"; "999"; "099"; "000" ]

let truncated_fixed () =
  invalid (decode [ "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nabc" ])

let truncated_chunk () = invalid (decode [ chunks_header ^ "5\r\nabc" ])
let incomplete_chunk () = invalid (decode [ chunks_header ^ "3\r\nabc\r\n" ])

let largest_chunk () =
  invalid (decode [ chunks_header ^ "7fffffffffffffff\r\nx" ])

let valid framing () =
  let chunks = [ "alpha"; ""; "\r\nbeta\000" ] in
  let body = Model.body chunks in
  let wire = Model.wire ~status:200 framing chunks in
  List.iter
    (fun width ->
      match Model.split ~width wire with
      | Some fragments -> accepted ~status:200 ~body (decode fragments)
      | None -> Alcotest.fail "positive fragment width rejected")
    [ 1; 2; 3; 7; String.length wire ]

let valid_status () =
  List.iter
    (fun status ->
      let wire = Model.wire ~status Model.Fixed [ "" ] in
      accepted ~status ~body:"" (decode [ wire ]))
    [ 100; 199; 200; 299; 300; 399; 400; 499; 500; 599 ]

let tests =
  [
    Alcotest.test_case "signed and overflowing chunk lengths" `Quick
      signed_chunk;
    Alcotest.test_case "exact three digit status range" `Quick malformed_status;
    Alcotest.test_case "status numeric range" `Quick out_of_range_status;
    Alcotest.test_case "fixed body EOF preserves parse failure" `Quick
      truncated_fixed;
    Alcotest.test_case "chunk body EOF preserves parse failure" `Quick
      truncated_chunk;
    Alcotest.test_case "missing terminal chunk is rejected" `Quick
      incomplete_chunk;
    Alcotest.test_case "largest chunk does not allocate its declaration" `Quick
      largest_chunk;
    Alcotest.test_case "fixed response fragmentation" `Quick (valid Model.Fixed);
    Alcotest.test_case "chunked response fragmentation" `Quick
      (valid Model.Chunked);
    Alcotest.test_case "close delimited response fragmentation" `Quick
      (valid Model.Until_eof);
    Alcotest.test_case "valid status boundary controls" `Quick valid_status;
  ]

let messages =
  let open QCheck2.Gen in
  triple (int_range 200 599)
    (oneof_list [ Model.Fixed; Model.Chunked; Model.Until_eof ])
    (list_size (int_range 0 12) (string_size (int_range 0 32)))

let properties =
  [
    QCheck2.Test.make ~name:"H1 agrees with list body under fragmentation"
      ~count:1000
      QCheck2.Gen.(pair messages (int_range 1 80))
      (fun ((status, framing, chunks), width) ->
        (* No-body status semantics belong to HTTP, not the fragmentation law. *)
        let status = if status = 204 || status = 304 then 200 else status in
        let wire = Model.wire ~status framing chunks in
        match Model.split ~width wire with
        | None -> false
        | Some fragments -> (
            match decode fragments with
            | Accepted (got_status, body) ->
                got_status = status && body = Model.body chunks
            | Invalid _ | Raised _ | Incomplete -> false));
  ]
