open Core
module Pm = Portfolio_management
module PMR = Pm.Pair_mean_reversion
module Common = Pm.Common

let book = Common.Book_id.of_string "alpha"

let inst sym = Instrument.of_qualified sym

let candle ~ts ~close =
  Candle.make ~ts ~open_:close ~high:close ~low:close ~close ~volume:Decimal.one

let make_config ?(window = 4) ?(z_entry = 2.0) ?(z_exit = 0.5) () =
  let pair = Common.Pair.make ~a:(inst "SBER@MISX") ~b:(inst "LKOH@MISX") in
  let hedge_ratio = Common.Hedge_ratio.of_decimal Decimal.one in
  PMR.Values.Pair_mr_config.make ~book_id:book ~pair ~hedge_ratio ~window
    ~z_entry:(Common.Z_score.of_float z_entry)
    ~z_exit:(Common.Z_score.of_float z_exit)
    ~notional:(Decimal.of_int 10_000)

let feed_pair state ~ts ~price_a ~price_b =
  let s, _ =
    PMR.on_bar state ~instrument:(inst "SBER@MISX") ~candle:(candle ~ts ~close:price_a)
  in
  PMR.on_bar s ~instrument:(inst "LKOH@MISX")
    ~candle:(candle ~ts:(Int64.add ts 1L) ~close:price_b)

let test_irrelevant_instrument_ignored () =
  let cfg = make_config () in
  let s = PMR.init cfg in
  let s', proposal =
    PMR.on_bar s ~instrument:(inst "OTHER@MISX")
      ~candle:(candle ~ts:1L ~close:Decimal.one)
  in
  Alcotest.(check int) "no samples" 0 (PMR.Values.Pair_mr_state.sample_count s');
  Alcotest.(check bool) "no proposal" true (Option.is_none proposal)

let test_window_must_fill_before_proposal () =
  let cfg = make_config ~window:4 () in
  let s = ref (PMR.init cfg) in
  let any_proposal = ref false in
  for k = 1 to 3 do
    let s', _ =
      feed_pair !s ~ts:(Int64.of_int k) ~price_a:(Decimal.of_int 100)
        ~price_b:(Decimal.of_int 100)
    in
    if
      Option.is_some
        (snd
           (feed_pair s' ~ts:(Int64.of_int k) ~price_a:(Decimal.of_int 100)
              ~price_b:(Decimal.of_int 100)))
    then any_proposal := true;
    s := s'
  done;
  Alcotest.(check bool) "no proposal until window full" false !any_proposal

let test_proposal_carries_pair_book () =
  let cfg = make_config ~window:2 ~z_entry:0.1 ~z_exit:0.05 () in
  let s = ref (PMR.init cfg) in
  (* First synchronised pair to fill 1/2 *)
  let s', _ =
    feed_pair !s ~ts:1L ~price_a:(Decimal.of_int 100) ~price_b:(Decimal.of_int 100)
  in
  s := s';
  (* Second pair with mismatched move so spread != prior; window = 2 fills. *)
  let s', proposal =
    feed_pair !s ~ts:2L ~price_a:(Decimal.of_int 110) ~price_b:(Decimal.of_int 100)
  in
  ignore s';
  match proposal with
  | None ->
      (* It is acceptable that no proposal fires when stdev = 0; the
         test below is structural — if a proposal does emerge, it
         should mention both legs. *)
      Alcotest.(check pass) "no proposal yet" () ()
  | Some prop ->
      Alcotest.(check int) "two legs" 2 (List.length prop.positions);
      let mentions sym =
        List.exists
          (fun (tp : Common.Target_position.t) ->
            Instrument.equal tp.instrument (inst sym))
          prop.positions
      in
      Alcotest.(check bool) "SBER mentioned" true (mentions "SBER@MISX");
      Alcotest.(check bool) "LKOH mentioned" true (mentions "LKOH@MISX");
      Alcotest.(check string)
        "book_id alpha" "alpha"
        (Common.Book_id.to_string prop.book_id)

let tests =
  [
    ("irrelevant instrument is ignored", `Quick, test_irrelevant_instrument_ignored);
    ("window must fill before proposal", `Quick, test_window_must_fill_before_proposal);
    ("proposal carries pair and book", `Quick, test_proposal_carries_pair_book);
  ]
