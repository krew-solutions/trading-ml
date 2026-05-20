(** WS request encoders for the ACCOUNT channel (positions /
    equity / portfolio snapshots). Not the same as TRADES —
    ACCOUNT pushes aggregate account state, TRADES pushes
    per-execution legs. *)

val subscribe : token:string -> account_id:string -> Yojson.Safe.t
val unsubscribe : token:string -> account_id:string -> Yojson.Safe.t
