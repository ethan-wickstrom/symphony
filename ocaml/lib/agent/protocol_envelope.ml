type rpc_error = { code : int64; message : string; data : Json.t option }
type reply = Success of Json.t | Failure of rpc_error

type view =
  | Request of { id : Protocol_id.t; method_ : string; params : Json.t option }
  | Notification of { method_ : string; params : Json.t option }
  | Response of { id : Protocol_id.t; reply : reply }

type t = { decoded : view; source : Json.t }

type error =
  | Not_object
  | Ambiguous
  | Invalid_id of Protocol_id.error
  | Invalid_method
  | Invalid_rpc_error
  | Forbidden_header
  | Invalid_json

let max_method_bytes = 256
let id_key = "id"
let method_key = "method"
let params_key = "params"
let result_key = "result"
let error_key = "error"
let header_key = "jsonrpc"
let code_key = "code"
let message_key = "message"
let data_key = "data"
let ( let* ) = Result.bind
let view value = value.decoded
let encode value = Ok value.source

let wire_id value =
  Result.map_error (fun error -> Invalid_id error) (Protocol_id.decode value)

let checked_method name =
  if name = "" || String.length name > max_method_bytes then
    Error Invalid_method
  else if not (Text.valid_utf8 name) then Error Invalid_method
  else Ok name

let method_name value =
  match Json.view value with
  | Json.String name -> checked_method name
  | Json.Null | Json.Bool _ | Json.Number _ | Json.Array _ | Json.Object _ ->
      Error Invalid_method

let rpc_error value =
  let* fields =
    match Json.view value with
    | Json.Object fields -> Ok fields
    | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
        Error Invalid_rpc_error
  in
  let* code =
    match List.assoc_opt code_key fields with
    | Some code ->
        Result.map_error (fun _ -> Invalid_rpc_error) (Protocol_id.decode code)
    | None -> Error Invalid_rpc_error
  in
  let* code =
    match Protocol_id.view code with
    | Protocol_id.Integer code -> Ok code
    | Protocol_id.String _ -> Error Invalid_rpc_error
  in
  let* message =
    match Option.map Json.view (List.assoc_opt message_key fields) with
    | Some (Json.String message) -> Ok message
    | None
    | Some
        (Json.Null | Json.Bool _ | Json.Number _ | Json.Array _ | Json.Object _)
      -> Error Invalid_rpc_error
  in
  Ok { code; message; data = List.assoc_opt data_key fields }

let decode source =
  match Json.view source with
  | Json.Object fields ->
      if List.mem_assoc header_key fields then Error Forbidden_header
      else
        let id = List.assoc_opt id_key fields in
        let method_ = List.assoc_opt method_key fields in
        let params = List.assoc_opt params_key fields in
        let result = List.assoc_opt result_key fields in
        let error = List.assoc_opt error_key fields in
        let* decoded =
          match (id, method_, params, result, error) with
          | Some id, Some method_, params, None, None ->
              let* id = wire_id id in
              let* method_ = method_name method_ in
              Ok (Request { id; method_; params })
          | None, Some method_, params, None, None ->
              let* method_ = method_name method_ in
              Ok (Notification { method_; params })
          | Some id, None, None, Some result, None ->
              let* id = wire_id id in
              Ok (Response { id; reply = Success result })
          | Some id, None, None, None, Some error ->
              let* id = wire_id id in
              let* error = rpc_error error in
              Ok (Response { id; reply = Failure error })
          | _ -> Error Ambiguous
        in
        (* Keep opaque additive fields so decoding never silently rewrites wire data. *)
        Ok { decoded; source }
  | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
      Error Not_object

let object_value fields =
  Result.map_error (fun _ -> Invalid_json) (Json.of_view (Json.Object fields))

let string_value value =
  Result.map_error (fun _ -> Invalid_json) (Json.of_view (Json.String value))

let id_value id =
  Result.map_error (fun error -> Invalid_id error) (Protocol_id.encode id)

let with_params fields params =
  match params with
  | None -> fields
  | Some value -> (params_key, value) :: fields

let request ~id ~method_ ~params =
  let* id = id_value id in
  let* method_ = checked_method method_ in
  let* method_ = string_value method_ in
  let* source =
    object_value (with_params [ (id_key, id); (method_key, method_) ] params)
  in
  decode source

let notification ~method_ ~params =
  let* method_ = checked_method method_ in
  let* method_ = string_value method_ in
  let* source = object_value (with_params [ (method_key, method_) ] params) in
  decode source

let error_value { code; message; data } =
  let* code = id_value (Protocol_id.of_int64 code) in
  let* message = string_value message in
  let fields = [ (code_key, code); (message_key, message) ] in
  let fields =
    match data with
    | None -> fields
    | Some data -> (data_key, data) :: fields
  in
  object_value fields

let response ~id ~reply =
  let* id = id_value id in
  let* field =
    match reply with
    | Success result -> Ok (result_key, result)
    | Failure error ->
        let* error = error_value error in
        Ok (error_key, error)
  in
  let* source = object_value [ (id_key, id); field ] in
  decode source
