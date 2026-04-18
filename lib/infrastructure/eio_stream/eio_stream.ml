let of_eio_stream (s : 'a Eio.Stream.t) : 'a Stream.t =
  let rec go () = Seq.Cons (Eio.Stream.take s, go) in
  go
