type t = {
  ticker : Ticker.t;
  venue  : Mic.t;
  isin   : Isin.t option;
  board  : Board.t option;
}

let make ~ticker ~venue ?isin ?board () =
  { ticker; venue; isin; board }

let ticker t = t.ticker
let venue  t = t.venue
let isin   t = t.isin
let board  t = t.board

(** Identity rule: ISIN+MIC if both sides have ISIN, else Ticker+MIC.
    Board is intentionally excluded — see {!t}. *)
let equal a b =
  Mic.equal a.venue b.venue
  && (match a.isin, b.isin with
      | Some x, Some y -> Isin.equal x y
      | None, None     -> Ticker.equal a.ticker b.ticker
      | _ -> false)

let compare a b =
  let c = Mic.compare a.venue b.venue in
  if c <> 0 then c
  else match a.isin, b.isin with
    | Some x, Some y -> Isin.compare x y
    | None, None     -> Ticker.compare a.ticker b.ticker
    | None, Some _   -> -1
    | Some _, None   -> 1

let hash t =
  let key = match t.isin with
    | Some i -> "I:" ^ Isin.to_string i
    | None   -> "T:" ^ Ticker.to_string t.ticker
  in
  Hashtbl.hash (Mic.to_string t.venue, key)

let pp ppf t =
  Format.fprintf ppf "%a@@%a%s%s"
    Ticker.pp t.ticker
    Mic.pp t.venue
    (match t.board with
     | Some b -> "/" ^ Board.to_string b
     | None -> "")
    (match t.isin with
     | Some i -> " [" ^ Isin.to_string i ^ "]"
     | None -> "")

let yojson_of_t t : Yojson.Safe.t =
  let opt key f = function
    | None -> []
    | Some v -> [ key, f v ]
  in
  `Assoc (
    [ "ticker", Ticker.yojson_of_t t.ticker;
      "mic",    Mic.yojson_of_t t.venue ]
    @ opt "isin"  Isin.yojson_of_t  t.isin
    @ opt "board" Board.yojson_of_t t.board)

let to_qualified t =
  let base = Ticker.to_string t.ticker ^ "@" ^ Mic.to_string t.venue in
  match t.board with
  | None -> base
  | Some b -> base ^ "/" ^ Board.to_string b

(** Split ["KEY=VALUE&..."] into an association list. Local helper for
    the optional [?isin=] suffix in {!of_qualified}; we don't pull in
    [Uri] just for this. *)
let parse_query s =
  String.split_on_char '&' s
  |> List.filter_map (fun kv ->
       match String.index_opt kv '=' with
       | None -> None
       | Some i ->
         Some (String.sub kv 0 i,
               String.sub kv (i + 1) (String.length kv - i - 1)))

let of_qualified raw =
  let s = String.trim raw in
  let body, isin_opt =
    match String.index_opt s '?' with
    | None -> s, None
    | Some i ->
      let body = String.sub s 0 i in
      let q = String.sub s (i + 1) (String.length s - i - 1) in
      let isin = List.assoc_opt "isin" (parse_query q) in
      body, Option.map Isin.of_string isin
  in
  match String.index_opt body '@' with
  | None ->
    invalid_arg ("Instrument.of_qualified: missing @MIC in " ^ raw)
  | Some at ->
    let ticker = String.sub body 0 at in
    let rest = String.sub body (at + 1) (String.length body - at - 1) in
    let mic, board =
      match String.index_opt rest '/' with
      | None -> rest, None
      | Some j ->
        String.sub rest 0 j,
        Some (String.sub rest (j + 1) (String.length rest - j - 1))
    in
    make
      ~ticker:(Ticker.of_string ticker)
      ~venue:(Mic.of_string mic)
      ?isin:isin_opt
      ?board:(Option.map Board.of_string board)
      ()

let t_of_yojson = function
  | `Assoc fields ->
    let find k = try Some (List.assoc k fields) with Not_found -> None in
    let req k = match find k with
      | Some v -> v
      | None -> invalid_arg ("Instrument.t_of_yojson: missing " ^ k)
    in
    let opt k f = match find k with
      | None | Some `Null -> None
      | Some v -> Some (f v)
    in
    make
      ~ticker:(Ticker.t_of_yojson (req "ticker"))
      ~venue:(Mic.t_of_yojson (req "mic"))
      ?isin:(opt "isin" Isin.t_of_yojson)
      ?board:(opt "board" Board.t_of_yojson)
      ()
  | j -> invalid_arg ("Instrument.t_of_yojson: " ^ Yojson.Safe.to_string j)
