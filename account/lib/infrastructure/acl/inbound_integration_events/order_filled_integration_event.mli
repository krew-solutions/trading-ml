(** Account-side mirror of the paper_broker BC's "order filled"
    integration event published on [in-memory://broker.order-filled].

    Structurally identical wire shape to the producing BC's outbound
    [Order_filled_integration_event.t], but owned by Account so its
    commit-fill subscriber listens autonomously. Cross-BC types are
    duplicated, never imported — the bridge between the producer's
    outbound event and this Account mirror is wired by the
    composition root via the bus URI; no code dependency between
    paper_broker and account libraries exists.

    [reservation_id] is the cross-BC saga key — minted by Account
    on the original {!Reserve_command}, echoed back through the saga
    on every leg, and used here to look up the matching reservation
    for {!Account.Portfolio.commit_fill}. *)

type t = {
  correlation_id : string;
      (** Saga-instance identifier echoed by paper_broker from the
          inbound {!Submit_order_command}. *)
  reservation_id : int;
      (** Echoed from {!Submit_order_command}; resolves the
          reservation lookup. *)
  quantity : string;  (** Actual filled quantity, decimal string. *)
  price : string;  (** Actual fill price, decimal string. *)
  fee : string;  (** Actual fee charged, decimal string. *)
}
[@@deriving yojson]
