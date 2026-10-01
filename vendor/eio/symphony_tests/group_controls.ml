external controls : unit -> bool = "symphony_group_controls"

let () =
  if not (controls ()) then failwith "snapshot negative control failed";
  print_endline
    "PASS: empty/zombie snapshots accepted; live/exiting members, query \
     errors, malformed/full/oversized snapshots rejected"
