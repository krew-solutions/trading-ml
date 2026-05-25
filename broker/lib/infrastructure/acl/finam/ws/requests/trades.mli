(** WS request encoders for the TRADES channel — account-scoped
    trade-execution push feed (one envelope per [trade_id]).
    Load-bearing input for the broker's
    [Trade_executed_integration_event] producer. *)

val subscribe : token:string -> account_id:string -> Yojson.Safe.t
val unsubscribe : token:string -> account_id:string -> Yojson.Safe.t
