type 'a t = 'a * 'a list

let singleton x = (x, [])

let of_list = function
  | [] -> None
  | x :: xs -> Some (x, xs)

let to_list (x, xs) = x :: xs
let map f (x, xs) = (f x, List.map f xs)
let fold f acc xs = List.fold_left f acc (to_list xs)
let append (x, xs) ys = (x, xs @ to_list ys)
