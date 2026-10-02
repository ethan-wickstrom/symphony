type 'a comparator = 'a -> 'a -> int

let equal _ _ = 0

let then_by first second left right =
  let order = first left right in
  if order = 0 then second left right else order

let first_priority = 1
let last_priority = 4

let rank issue =
  match Issue.priority issue with
  | Some n when n >= first_priority && n <= last_priority -> Some n
  | Some _ | None -> None

let priority left right =
  match (rank left, rank right) with
  | Some a, Some b -> Int.compare a b
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> 0

let created_at left right =
  match (Issue.created_at left, Issue.created_at right) with
  | Some a, Some b -> Utc.compare a b
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> 0

let identifier left right =
  Issue_identifier.compare (Issue.identifier left) (Issue.identifier right)

let dispatch = then_by (then_by priority created_at) identifier
