open Core

let label
    ~(arr : Candle.t array)
    ~(atr : float option array)
    ~(i : int)
    ~(tp_mult : float)
    ~(sl_mult : float)
    ~(timeout : int) : int option =
  match atr.(i) with
  | None -> None
  | Some atr_t when atr_t <= 0.0 -> None
  | Some atr_t ->
      let close_t = Decimal.to_float arr.(i).Candle.close in
      let tp = close_t +. (tp_mult *. atr_t) in
      let sl = close_t -. (sl_mult *. atr_t) in
      let n = Array.length arr in
      let last = min (i + timeout) (n - 1) in
      let rec walk j =
        if j > last then Some 1
        else
          let h = Decimal.to_float arr.(j).Candle.high in
          let l = Decimal.to_float arr.(j).Candle.low in
          let tp_hit = h >= tp in
          let sl_hit = l <= sl in
          if tp_hit && sl_hit then Some 0
          else if tp_hit then Some 2
          else if sl_hit then Some 0
          else walk (j + 1)
      in
      walk (i + 1)
