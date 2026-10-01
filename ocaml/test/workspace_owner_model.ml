type t = {
  scope : string;
  issue_id : string;
  identifier : string;
  device : string;
  inode : string;
}

let equal a b =
  String.equal a.scope b.scope
  && String.equal a.issue_id b.issue_id
  && String.equal a.identifier b.identifier
  && String.equal a.device b.device
  && String.equal a.inode b.inode

let text = function
  | Some (`String value)
    when String.trim value <> ""
         && (not (String.contains value '\000'))
         && String.is_valid_utf_8 value -> Some value
  | Some _ | None -> None

let hex value =
  String.length value = 16
  && Seq.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       (String.to_seq value)

let of_json (input : Yojson.Safe.t) =
  match input with
  | `Assoc fields -> (
      let expected =
        [ "device"; "identifier"; "inode"; "issue_id"; "scope"; "version" ]
      in
      let actual = List.sort String.compare (List.map fst fields) in
      if not (List.equal String.equal expected actual) then None
      else
        let ( let* ) = Option.bind in
        let* () =
          match List.assoc_opt "version" fields with
          | Some (`Int 1) -> Some ()
          | Some _ | None -> None
        in
        let* scope = text (List.assoc_opt "scope" fields) in
        let* issue_id = text (List.assoc_opt "issue_id" fields) in
        let* identifier = text (List.assoc_opt "identifier" fields) in
        let* device = text (List.assoc_opt "device" fields) in
        let* inode = text (List.assoc_opt "inode" fields) in
        if not (hex device && hex inode) then None
        else
          match Workspace_key_model.derive identifier with
          | Error _ -> None
          | Ok _ -> Some { scope; issue_id; identifier; device; inode })
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
      None
