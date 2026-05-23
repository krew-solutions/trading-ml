(* Refer to the atdgen-generated raw type rather than the
   [Trading_config] wrapper: in dune wrapped libraries the
   main module sits at the top of the dep graph, so submodules
   must not depend on it. The raw record from [_t] is exactly
   the same shape. *)
module T = Trading_config_t

(* Per-field "later wins" combinator for an option-typed field. *)
let pick (base : 'a option) (overlay : 'a option) : 'a option =
  match overlay with
  | Some _ -> overlay
  | None -> base

(* Pick records field-by-field; if both sides have a Some record,
   recurse into per-field merge. Otherwise, plain "later wins"
   on the option wrapper. *)
let merge_server (base : T.server option) (overlay : T.server option) : T.server option =
  match (base, overlay) with
  | None, x | x, None -> x
  | Some b, Some o -> Some { T.host = pick b.host o.host; port = pick b.port o.port }

let merge_engine (base : T.engine option) (overlay : T.engine option) : T.engine option =
  match (base, overlay) with
  | None, x | x, None -> x
  | Some b, Some o ->
      Some
        {
          T.strategy = pick b.strategy o.strategy;
          symbol = pick b.symbol o.symbol;
          paper_mode = pick b.paper_mode o.paper_mode;
        }

let merge_logging (base : T.logging option) (overlay : T.logging option) :
    T.logging option =
  match (base, overlay) with
  | None, x | x, None -> x
  | Some b, Some o -> Some { T.level = pick b.level o.level }

(* [bars] is treated as a whole-field override (overlay replaces
   base if Some). Per-element merge (union / dedup) would be more
   subtle than is useful here: an operator who wants to add one
   bar to the default set typically just copies the full list
   into local.config.json. *)
let merge_watchlist (base : T.watchlist option) (overlay : T.watchlist option) :
    T.watchlist option =
  match (base, overlay) with
  | None, x | x, None -> x
  | Some b, Some o -> Some { T.bars = pick b.bars o.bars }

(* Broker is a variant; per-field overlay on credentials would
   require matching both sides to the same constructor. We take
   the whole variant from the overlay if present — operationally
   simpler and matches the "I want to switch broker for this
   deployment" use case. To override a single credential field
   without retyping the whole variant, the operator sets the
   env-var override layer (which is field-shaped). *)
let merge_broker (base : T.broker option) (overlay : T.broker option) : T.broker option =
  pick base overlay

let merge (base : T.t) (overlay : T.t) : T.t =
  {
    T.broker = merge_broker base.broker overlay.broker;
    server = merge_server base.server overlay.server;
    engine = merge_engine base.engine overlay.engine;
    watchlist = merge_watchlist base.watchlist overlay.watchlist;
    logging = merge_logging base.logging overlay.logging;
  }
