(** BCS wire-string ↔ {!Core.Timeframe.t} mapping. Reverse of
    {!Rest.timeframe_wire}. *)

open Core

val of_string : string -> Timeframe.t option
