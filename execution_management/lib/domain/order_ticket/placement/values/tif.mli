(** Time-in-force discipline supplied to the venue alongside the
    order. Mirrors FIX TimeInForce semantics. *)

type t =
  | Gtc  (** Good-till-cancel — rests on the book until filled / cancelled. *)
  | Day  (** Day order — auto-cancels at session close. *)
  | Ioc  (** Immediate-or-cancel — fills what's available now, cancels the rest. *)
  | Fok  (** Fill-or-kill — fully fillable now or cancelled outright. *)
