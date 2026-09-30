type t = { config : Config_value.t; prompt : string; file : Workflow_path.t }

type error =
  | Parse_error of Diagnostic.t
  | Front_matter_not_map of Diagnostic.t

let max_input_bytes = 1_048_576
let delimiter = "---"
let empty_mapping = "{}"

let diagnostic file message remedy =
  Diagnostic.make
    ~site:
      (Diagnostic.Workflow
         { file = Workflow_path.display file; key = None; line = None })
    ~message ~remedy

let delimiter_line line =
  String.starts_with ~prefix:delimiter line && String.trim line = delimiter

let split source =
  if not (String.starts_with ~prefix:delimiter source) then
    Ok (empty_mapping, source)
  else
    match String.split_on_char '\n' source with
    | opening :: lines when delimiter_line opening ->
        let rec close acc = function
          | [] -> Error "unterminated workflow front matter"
          | line :: remaining ->
              if delimiter_line line then
                Ok
                  ( String.concat "\n" (List.rev acc) ^ "\n",
                    String.concat "\n" remaining )
              else close (line :: acc) remaining
        in
        close [ opening ] lines
    | [] | _ :: _ -> Ok (empty_mapping, source)

let parse ~file source =
  if String.length source > max_input_bytes then
    Error
      (Parse_error
         (diagnostic file "workflow source exceeds 1048576 bytes"
            "Shorten WORKFLOW.md to at most 1048576 bytes."))
  else
    match split source with
    | Error message ->
        Error
          (Parse_error
             (diagnostic file message
                "Close the YAML front matter with an unindented --- line."))
    | Ok (front_matter, body) -> (
        match Config_value.parse front_matter with
        | Error message ->
            Error
              (Parse_error
                 (diagnostic file message
                    "Fix the YAML front matter; use one bounded mapping with \
                     unique string keys."))
        | Ok config -> (
            match Config_value.view config with
            | Config_value.Mapping _ ->
                Ok { config; prompt = String.trim body; file }
            | Config_value.Null
            | Config_value.Bool _
            | Config_value.Number _
            | Config_value.String _
            | Config_value.Sequence _ ->
                Error
                  (Front_matter_not_map
                     (diagnostic file "workflow front matter is not a mapping"
                        "Use a YAML mapping, or remove front matter entirely."))
            ))

let config document = document.config
let prompt document = document.prompt
let file document = document.file
