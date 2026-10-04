let get = function
  | Ok value -> value
  | Error _ -> failwith "Checked codec fixture construction failed"

let string value = get (Json.of_view (Json.String value))

let encode (fixture : Protocol_codec_test.fixture) =
  get
    (Json.of_view
       (Json.Object
          [
            ("name", string fixture.Protocol_codec_test.name);
            ("schema", string fixture.Protocol_codec_test.schema);
            ("value", fixture.Protocol_codec_test.value);
          ]))

let () =
  List.iter
    (fun fixture -> print_endline (Json.encode (encode fixture)))
    (Protocol_codec_test.fixtures ())
