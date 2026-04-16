(** Shared fixtures for per-indicator test files. Keeps every spec file
    short and focused on the indicator's actual invariants. *)

open Core

let candle ?high ?low ?(volume=1.0) close =
  let h = match high with Some h -> h | None -> close in
  let l = match low  with Some l -> l | None -> close in
  Candle.make ~ts:0L
    ~open_:(Decimal.of_float close)
    ~high:(Decimal.of_float h)
    ~low:(Decimal.of_float l)
    ~close:(Decimal.of_float close)
    ~volume:(Decimal.of_float volume)

let feed ind cs =
  List.fold_left (fun i c -> Indicators.Indicator.update i c) ind cs

let scalar ind =
  match Indicators.Indicator.value ind with
  | Some (_, [v]) -> v
  | _ -> Float.nan

let values ind =
  match Indicators.Indicator.value ind with
  | Some (_, vs) -> vs
  | None -> []
