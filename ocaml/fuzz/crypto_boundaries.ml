module Rsa = Mirage_crypto_pk.Rsa
module Pss = Rsa.PSS (Digestif.SHA256)

type input = Bytes of string | Rejected of string

(* Crowbar's byte reader accepts at most 256 bytes per request. *)
let max_bytes = 256
let rsa_bits = 1024
let rsa_bytes = rsa_bits / 8
let rsa_exponent = 65537

let no_inputs : ('a, 'a) Crowbar.gens =
  let open! Crowbar in
  []

let ( @> ) generator rest =
  (Crowbar.( :: ) (generator, rest) : (_, _) Crowbar.gens)

let raw =
  Crowbar.map
    (Crowbar.range (max_bytes + 1) @> Crowbar.bytes_fixed max_bytes @> no_inputs)
    (fun length bytes -> String.sub bytes 0 length)

let checked = function
  | Ok value -> value
  | Error _ -> Crowbar.fail "Valid crypto fixture was rejected"

let invalid_format = function
  | Error `Invalid_format -> ()
  | Error error ->
      Crowbar.failf "Short point returned %a" Mirage_crypto_ec.pp_error error
  | Ok _ -> Crowbar.fail "Short compressed point was accepted"

let register_curve name (module Curve : Mirage_crypto_ec.Dh_dsa) =
  let length = Curve.Dsa.byte_length in
  let scalar = String.make (length - 1) '\000' ^ "\001" in
  let secret, valid =
    checked (Curve.Dh.secret_of_octets ~compress:true scalar)
  in
  let short =
    Crowbar.map
      (Crowbar.range length
      @> Crowbar.choose [ Crowbar.const '\002'; Crowbar.const '\003' ]
      @> Crowbar.bytes_fixed length @> no_inputs)
      (fun count prefix bytes ->
        Rejected (String.make 1 prefix ^ String.sub bytes 0 count))
  in
  let input =
    Crowbar.choose
      [
        Crowbar.map (raw @> no_inputs) (fun bytes -> Bytes bytes);
        short;
        Crowbar.const (Bytes "");
        Crowbar.const (Bytes "\000");
        Crowbar.const (Bytes "\001");
        Crowbar.const (Bytes valid);
      ]
  in
  Crowbar.add_test ~name:(name ^ " public decode and DH octet rejection")
    (input @> no_inputs) (function
    | Rejected bytes ->
        invalid_format (Curve.Dsa.pub_of_octets bytes);
        invalid_format (Curve.Dh.key_exchange secret bytes)
    | Bytes bytes -> (
        (match Curve.Dsa.pub_of_octets bytes with
        | Error _ -> ()
        | Ok public ->
            let encoded = Curve.Dsa.pub_to_octets ~compress:true public in
            let decoded = checked (Curve.Dsa.pub_of_octets encoded) in
            Crowbar.check_eq encoded
              (Curve.Dsa.pub_to_octets ~compress:true decoded));
        match Curve.Dh.key_exchange secret bytes with
        | Error _ -> ()
        | Ok shared -> Crowbar.check_eq length (String.length shared)))

let register_rsa () =
  (* This checked synthetic modulus is the fixed rejection fixture, not a key
     generated with ambient entropy or a new DER parser. *)
  let key =
    checked
      (Rsa.pub ~e:(Z.of_int rsa_exponent)
         ~n:(Z.pred (Z.shift_left Z.one rsa_bits)))
  in
  let signature value =
    String.make (rsa_bytes - 1) '\000' ^ String.make 1 value
  in
  let input =
    Crowbar.choose
      [
        Crowbar.map (raw @> no_inputs) (fun bytes -> Bytes bytes);
        Crowbar.const (Rejected "");
        Crowbar.const (Rejected "\000");
        Crowbar.const (Rejected "\001");
        Crowbar.const (Rejected (signature '\000'));
        Crowbar.const (Rejected (signature '\001'));
      ]
  in
  Crowbar.add_test ~name:"RSA PKCS1 and PSS Message verification rejection"
    (input @> raw @> no_inputs)
    (fun input payload ->
      let signature =
        match input with
        | Bytes bytes | Rejected bytes -> bytes
      in
      let message = `Message payload in
      let pkcs1 =
        Rsa.PKCS1.verify
          ~hashp:(function
            | `SHA256 -> true
            | _ -> false)
          ~key ~signature message
      in
      let pss = Pss.verify ~key ~signature message in
      match input with
      | Bytes _ -> ()
      | Rejected _ -> Crowbar.check ((not pkcs1) && not pss))

let register () =
  register_curve "P256" (module Mirage_crypto_ec.P256);
  register_curve "P384" (module Mirage_crypto_ec.P384);
  register_curve "P521" (module Mirage_crypto_ec.P521);
  register_rsa ()
