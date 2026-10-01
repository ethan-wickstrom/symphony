module Port = struct
  module Pure = Clock.Pure

  type t = unit

  let unavailable () = Crowbar.fail "pure HTTP fuzzing invoked a clock"
  let now () = unavailable ()
  let sleep_until () _ = unavailable ()
  let sample () = unavailable ()
end

module Native = Native_http.Make (Port)

let default_endpoint = "https://api.linear.app/graphql"
let fixture_token = "fuzz-credential-fixture"

let pem_sample =
  {|-----BEGIN CERTIFICATE-----
MIIBszCCAVmgAwIBAgIUTu4bwSDvgM65d2KfntwgK9G20fMwCgYIKoZIzj0EAwIw
JzElMCMGA1UEAwwcU3ltcGhvbnkgTmF0aXZlIEhUVFAgVGVzdCBDQTAeFw0yMDAx
MDEwMDAwMDBaFw00MDAxMDEwMDAwMDBaMCcxJTAjBgNVBAMMHFN5bXBob255IE5h
dGl2ZSBIVFRQIFRlc3QgQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAT+ku6T
YJcuLAMyw0hSgD6s/esokRgalTDfgOt2jYtVk1KiKCzBXW+jP5pnCZuM6jpCJN07
Zwgz3AGVibyUK8jco2MwYTAdBgNVHQ4EFgQUC133evNo7Qz91i0Ua0ltRvhAhC8w
HwYDVR0jBBgwFoAUC133evNo7Qz91i0Ua0ltRvhAhC8wDwYDVR0TAQH/BAUwAwEB
/zAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwIDSAAwRQIgTpOTgBahp77CwfHk
pvbiu9jHrWWRZ0lh3PuVkhGuo4sCIQDX7T2f7qnWT4MpdyiJcHc2fUp/Qm8jK6ZA
5JcdQOTpGw==
-----END CERTIFICATE-----
|}

let checked = function
  | Ok value -> value
  | Error error -> Crowbar.fail (Diagnostic.render error)

let () = ignore (checked (Native.trust ~pem:pem_sample))

let signature = function
  | Ok _ -> (true, "")
  | Error error -> (false, Diagnostic.render error)

let endpoint source =
  let first = Native.endpoint source in
  Crowbar.check_eq (signature first) (signature (Native.endpoint source));
  match first with
  | Error _ -> ()
  | Ok destination ->
      let seal () =
        checked
          (Native.credential destination ~scheme:Native.Authorization_value
             ~token:fixture_token)
      in
      Crowbar.check (Native.equal (seal ()) (seal ()))

let credential source token =
  let destination =
    match Native.endpoint source with
    | Ok destination -> destination
    | Error _ -> checked (Native.endpoint default_endpoint)
  in
  let actual =
    Native.credential destination ~scheme:Native.Authorization_value ~token
  in
  let expected =
    String.trim token <> ""
    && String.for_all
         (fun c ->
           let byte = Char.code c in
           byte >= 32 && byte <> 127)
         token
  in
  Crowbar.check_eq expected (Result.is_ok actual);
  Crowbar.check_eq (signature actual)
    (signature
       (Native.credential destination ~scheme:Native.Authorization_value ~token));
  match actual with
  | Error _ -> ()
  | Ok sealed ->
      Crowbar.check (Native.equal sealed sealed);
      let changed =
        checked
          (Native.credential destination ~scheme:Native.Authorization_value
             ~token:(token ^ fixture_token))
      in
      Crowbar.check (not (Native.equal sealed changed));
      Crowbar.check_eq (Native.redacted sealed) (Native.redacted changed)

let trust source =
  Crowbar.check_eq
    (signature (Native.trust ~pem:source))
    (signature (Native.trust ~pem:source))

type reading =
  | Awaiting
  | Receiving of int
  | Finished of int
  | Rejected
  | Defect of exn

type outcome = Accepted of int * string | Invalid | Incomplete

(* A final codec observation can reject a response after its body EOF callback. *)
let decode fragments =
  let reading = ref Awaiting in
  let body = Buffer.create 128 in
  let response_handler response reader =
    reading := Receiving (H1.Status.to_code response.H1.Response.status);
    let rec schedule () =
      H1.Body.Reader.schedule_read reader
        ~on_eof:(fun () ->
          match !reading with
          | Receiving status -> reading := Finished status
          | Awaiting | Finished _ | Rejected | Defect _ -> ())
        ~on_read:(fun bytes ~off ~len ->
          Buffer.add_string body (Bstr.sub_string bytes ~off ~len);
          schedule ())
    in
    schedule ()
  in
  let error_handler = function
    | `Malformed_response _ | `Invalid_response_body_length _ ->
        reading := Rejected
    | `Exn error -> reading := Defect error
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
        Crowbar.check (consumed >= 0 && consumed <= length);
        pending := String.sub !pending consumed (length - consumed);
        ignore (observe ())
  in
  List.iter feed fragments;
  (match observe () with
  | `Close -> ()
  | `Read ->
      ignore
        (H1.Client_connection.read_eof connection (Bstr.of_string !pending)
           ~off:0 ~len:(String.length !pending)));
  ignore (observe ());
  match !reading with
  | Finished status -> Accepted (status, Buffer.contents body)
  | Rejected -> Invalid
  | Receiving _ | Awaiting -> Incomplete
  | Defect error -> raise error

let fragments width source =
  let length = String.length source in
  let rec loop offset reversed =
    if offset = length then List.rev reversed
    else
      let size = min width (length - offset) in
      loop (offset + size) (String.sub source offset size :: reversed)
  in
  loop 0 []

let framing source width =
  Crowbar.check (width > 0);
  let whole = decode [ source ] in
  let split = decode (fragments width source) in
  Crowbar.check_eq whole split;
  match whole with
  | Accepted (_, body) ->
      Crowbar.check (String.length body <= String.length source)
  | Invalid | Incomplete -> ()
