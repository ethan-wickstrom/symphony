module Rsa = Mirage_crypto_pk.Rsa
module Pss = Rsa.PSS (Digestif.SHA256)

let checked = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "Crypto fixture constructor rejected valid input"

let rsa_bits = 1024
let rsa_exponent = 65537
let message = `Message "Symphony crypto rejection control"

let public_key () =
  (* A checked synthetic modulus suffices for rejecting these two integers. *)
  Rsa.pub ~e:(Z.of_int rsa_exponent) ~n:(Z.pred (Z.shift_left Z.one rsa_bits))
  |> checked

let signature value =
  String.make ((rsa_bits / 8) - 1) '\000' ^ String.make 1 (Char.chr value)

let pkcs1 value () =
  Alcotest.(check bool)
    "invalid signature rejects" false
    (Rsa.PKCS1.verify
       ~hashp:(function
         | `SHA256 -> true
         | _ -> false)
       ~key:(public_key ()) ~signature:(signature value) message)

let pss value () =
  Alcotest.(check bool)
    "invalid signature rejects" false
    (Pss.verify ~key:(public_key ()) ~signature:(signature value) message)

let raw value () =
  match Rsa.encrypt ~key:(public_key ()) (signature value) with
  | _ -> Alcotest.fail "Small RSA integer must raise Insufficient_key"
  | exception Rsa.Insufficient_key -> ()

let small_scalar length = String.make (length - 1) '\000' ^ "\001"

let rejected_point = function
  | Error `Invalid_format -> ()
  | Error error ->
      Alcotest.failf "Expected Invalid_format, received %a"
        Mirage_crypto_ec.pp_error error
  | Ok _ -> Alcotest.fail "Short compressed point was accepted"

let curve name (module Curve : Mirage_crypto_ec.Dh_dsa) =
  let length = Curve.Dsa.byte_length in
  let short_points run () =
    List.iter
      (fun prefix ->
        List.iter
          (fun count -> run (String.make 1 prefix ^ String.make count '\000'))
          (List.init length Fun.id))
      [ '\002'; '\003' ]
  in
  let decode =
    short_points (fun point -> rejected_point (Curve.Dsa.pub_of_octets point))
  in
  let exchange () =
    let secret, _ = checked (Curve.Dh.secret_of_octets (small_scalar length)) in
    short_points
      (fun point -> rejected_point (Curve.Dh.key_exchange secret point))
      ()
  in
  let valid () =
    let secret, point =
      checked (Curve.Dh.secret_of_octets ~compress:true (small_scalar length))
    in
    Alcotest.(check int) "compressed size" (length + 1) (String.length point);
    ignore (checked (Curve.Dsa.pub_of_octets point));
    let shared = checked (Curve.Dh.key_exchange secret point) in
    Alcotest.(check int) "shared coordinate size" length (String.length shared)
  in
  [
    Alcotest.test_case (name ^ " short decode") `Quick decode;
    Alcotest.test_case (name ^ " short exchange") `Quick exchange;
    Alcotest.test_case (name ^ " valid compressed point") `Quick valid;
  ]

let tests =
  List.concat_map
    (fun value ->
      let suffix = " " ^ string_of_int value in
      [
        Alcotest.test_case ("RSA PKCS1 rejects" ^ suffix) `Quick (pkcs1 value);
        Alcotest.test_case ("RSA PSS rejects" ^ suffix) `Quick (pss value);
        Alcotest.test_case
          ("RSA documented failure" ^ suffix)
          `Quick (raw value);
      ])
    [ 0; 1 ]
  @ curve "P256" (module Mirage_crypto_ec.P256)
  @ curve "P384" (module Mirage_crypto_ec.P384)
  @ curve "P521" (module Mirage_crypto_ec.P521)
