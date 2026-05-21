open Core

type leg = { instrument : Instrument.t; weight : Decimal.t }

type t =
  | Scalar of {
      book_id : Book_id.t;
      instrument : Instrument.t;
      direction : Direction.t;
      strength : Strength.t;
      source : Source.t;
      observed_at : int64;
    }
  | Coupled of {
      book_id : Book_id.t;
      legs : leg list;
      coupling : Coupling.t;
      source : Source.t;
      observed_at : int64;
    }

let scalar ~book_id ~instrument ~direction ~strength ~source ~observed_at =
  Scalar { book_id; instrument; direction; strength; source; observed_at }

let rec has_duplicate_sorted = function
  | a :: (b :: _ as rest) ->
      Instrument.equal a.instrument b.instrument || has_duplicate_sorted rest
  | _ -> false

let sum_abs_weights legs =
  List.fold_left
    (fun acc { weight; _ } -> Decimal.add acc (Decimal.abs weight))
    Decimal.zero legs

let coupled ~book_id ~legs ~coupling ~source ~observed_at =
  (match legs with
  | [] -> invalid_arg "Construction_intent.coupled: legs must be non-empty"
  | _ -> ());
  List.iter
    (fun { weight; instrument } ->
      if Decimal.compare (Decimal.abs weight) Decimal.one > 0 then
        invalid_arg
          (Printf.sprintf
             "Construction_intent.coupled: |weight| > 1 for instrument %s (got %s)"
             (Instrument.to_qualified instrument)
             (Decimal.to_string weight)))
    legs;
  let legs_sorted =
    List.sort (fun a b -> Instrument.compare a.instrument b.instrument) legs
  in
  if has_duplicate_sorted legs_sorted then
    invalid_arg "Construction_intent.coupled: duplicate instrument in legs";
  let s = sum_abs_weights legs_sorted in
  if Decimal.compare s Decimal.one > 0 then
    invalid_arg
      (Printf.sprintf "Construction_intent.coupled: Σ |weight| > 1 (got %s)"
         (Decimal.to_string s));
  Coupled { book_id; legs = legs_sorted; coupling; source; observed_at }

let book_id = function
  | Scalar s -> s.book_id
  | Coupled c -> c.book_id

let source = function
  | Scalar s -> s.source
  | Coupled c -> c.source

let observed_at = function
  | Scalar s -> s.observed_at
  | Coupled c -> c.observed_at
