(** BDD specification for ingesting public-tape prints into footprint
    bars.

    Expressed in terms of intent and observable facts — a forming bar
    stays silent until it seals, a sealed bar is announced with its
    order-flow shape, auction volume counts without skewing delta, a
    late print is ignored, and malformed prints are refused. No
    implementation detail (aggregate states, cluster internals) leaks
    into the step text. *)

module Gherkin = Gherkin_edsl
open Test_harness

let one_completed label ctx =
  match !(ctx.footprint_completed_pub) with
  | [ ie ] -> ie
  | other ->
      Alcotest.fail
        (Printf.sprintf "%s: expected exactly one completed footprint, got %d" label
           (List.length other))

(* All prints in the 10:00 five-minute bucket; the bucket boundary is
   10:05:00Z. *)
let t0 = "2024-01-15T10:00:00Z"
let t1 = "2024-01-15T10:02:00Z"
let t2 = "2024-01-15T10:03:30Z"
let t_next = "2024-01-15T10:05:30Z"
let t_earlier = "2024-01-15T10:01:00Z"

let first_print_opens_a_bar_silently =
  Gherkin.scenario "The first print opens a bar but announces nothing yet" fresh_ctx
    [
      Gherkin.given "no bar in progress" (fun ctx -> ctx);
      Gherkin.when_ "a buy of 5 SBER@MISX at 100 prints" (fun ctx ->
          ctx |> ingest ~symbol:"SBER@MISX" ~price:"100" ~size:"5" ~ts:t0 ~aggressor:"BUY");
      Gherkin.then_ "the print is accepted" (fun ctx ->
          match ctx.last_result with
          | Some (Ok ()) -> ()
          | _ -> Alcotest.fail "expected acceptance");
      Gherkin.then_ "no completed footprint is announced — the bar is still forming"
        (fun ctx ->
          Alcotest.(check int)
            "completed count" 0
            (List.length !(ctx.footprint_completed_pub)));
    ]

let prints_in_the_same_bucket_stay_silent =
  Gherkin.scenario "Prints within the same bucket accumulate without announcing" fresh_ctx
    [
      Gherkin.given "a bar in progress with one buy" (fun ctx ->
          ctx |> ingest ~symbol:"SBER@MISX" ~price:"100" ~size:"5" ~ts:t0 ~aggressor:"BUY");
      Gherkin.when_ "more prints arrive within the same five-minute bucket" (fun ctx ->
          ctx
          |> ingest ~symbol:"SBER@MISX" ~price:"101" ~size:"3" ~ts:t1 ~aggressor:"SELL"
          |> ingest ~symbol:"SBER@MISX" ~price:"100" ~size:"2" ~ts:t2
               ~aggressor:"UNSPECIFIED");
      Gherkin.then_ "still nothing is announced" (fun ctx ->
          Alcotest.(check int)
            "completed count" 0
            (List.length !(ctx.footprint_completed_pub)));
    ]

let crossing_into_the_next_bucket_announces_the_footprint =
  Gherkin.scenario
    "A print for the next bucket seals the bar and announces its order-flow shape"
    fresh_ctx
    [
      Gherkin.given "a bar accumulating a buy, a sell and an auction print" (fun ctx ->
          ctx
          |> ingest ~symbol:"SBER@MISX" ~price:"100" ~size:"5" ~ts:t0 ~aggressor:"BUY"
          |> ingest ~symbol:"SBER@MISX" ~price:"101" ~size:"3" ~ts:t1 ~aggressor:"SELL"
          |> ingest ~symbol:"SBER@MISX" ~price:"100" ~size:"2" ~ts:t2
               ~aggressor:"UNSPECIFIED");
      Gherkin.when_ "a print arrives for the following bucket" (fun ctx ->
          ctx
          |> ingest ~symbol:"SBER@MISX" ~price:"100" ~size:"1" ~ts:t_next ~aggressor:"BUY");
      Gherkin.then_ "exactly one completed footprint is announced, for the right bar"
        (fun ctx ->
          let ie = one_completed "seal" ctx in
          Alcotest.(check string) "instrument.ticker" "SBER" ie.instrument.ticker;
          Alcotest.(check string) "instrument.venue" "MISX" ie.instrument.venue;
          Alcotest.(check string) "timeframe" "M5" ie.timeframe;
          Alcotest.(check string) "open_ts" "2024-01-15T10:00:00Z" ie.open_ts);
      Gherkin.then_ "it carries the reconstructed OHLC of its own prints" (fun ctx ->
          let ie = one_completed "seal" ctx in
          Alcotest.(check string) "open" "100" ie.open_price;
          Alcotest.(check string) "high" "101" ie.high;
          Alcotest.(check string) "low" "100" ie.low;
          Alcotest.(check string) "close" "100" ie.close);
      Gherkin.then_ "it carries total volume, signed delta and the Point of Control"
        (fun ctx ->
          let ie = one_completed "seal" ctx in
          (* volume 5+3+2 = 10; delta = buy 5 - sell 3 = 2 (auction excluded);
             POC = price 100 (buy 5 + auction 2 = 7, beating 101's 3) *)
          Alcotest.(check string) "volume" "10" ie.volume;
          Alcotest.(check string) "delta" "2" ie.delta;
          Alcotest.(check string) "poc_price" "100" ie.poc_price;
          Alcotest.(check int) "clusters" 2 (List.length ie.clusters));
    ]

let auction_volume_counts_without_moving_delta =
  Gherkin.scenario "Auction volume is counted in total but never skews the delta"
    fresh_ctx
    [
      Gherkin.given "a bar with a buy and an equal-size auction print" (fun ctx ->
          ctx
          |> ingest ~symbol:"SBER@MISX" ~price:"100" ~size:"5" ~ts:t0 ~aggressor:"BUY"
          |> ingest ~symbol:"SBER@MISX" ~price:"100" ~size:"5" ~ts:t1
               ~aggressor:"UNSPECIFIED");
      Gherkin.when_ "the bar seals on the next bucket" (fun ctx ->
          ctx
          |> ingest ~symbol:"SBER@MISX" ~price:"100" ~size:"1" ~ts:t_next ~aggressor:"BUY");
      Gherkin.then_
        "total volume includes the auction print but delta reflects only the buy"
        (fun ctx ->
          let ie = one_completed "seal" ctx in
          Alcotest.(check string) "volume" "10" ie.volume;
          Alcotest.(check string) "delta" "5" ie.delta);
    ]

let a_late_print_is_ignored =
  Gherkin.scenario "A print for an already-passed bucket is ignored, not announced"
    fresh_ctx
    [
      Gherkin.given "a bar in progress in the 10:05 bucket" (fun ctx ->
          ctx
          |> ingest ~symbol:"SBER@MISX" ~price:"100" ~size:"5" ~ts:t_next ~aggressor:"BUY");
      Gherkin.when_ "a print for an earlier bucket arrives" (fun ctx ->
          ctx
          |> ingest ~symbol:"SBER@MISX" ~price:"100" ~size:"1" ~ts:t_earlier
               ~aggressor:"BUY");
      Gherkin.then_ "the print is accepted but changes nothing and announces nothing"
        (fun ctx ->
          (match ctx.last_result with
          | Some (Ok ()) -> ()
          | _ -> Alcotest.fail "a late print is not an error");
          Alcotest.(check int)
            "completed count" 0
            (List.length !(ctx.footprint_completed_pub)));
    ]

let malformed_print_is_refused =
  Gherkin.scenario
    "A malformed print is refused, reporting every bad field, announcing nothing"
    fresh_ctx
    [
      Gherkin.given "no bar in progress" (fun ctx -> ctx);
      Gherkin.when_ "a print arrives with a non-positive size and an unknown aggressor"
        (fun ctx ->
          ctx
          |> ingest ~symbol:"SBER@MISX" ~price:"100" ~size:"0" ~ts:t0 ~aggressor:"NOPE");
      Gherkin.then_ "every malformed field is reported together" (fun ctx ->
          match ctx.last_result with
          | Some (Error errs) ->
              let has_non_positive_size =
                List.exists
                  (function
                    | Ingest_h.Validation (Ingest_h.Non_positive_size "0") -> true
                    | _ -> false)
                  errs
              in
              let has_invalid_aggressor =
                List.exists
                  (function
                    | Ingest_h.Validation (Ingest_h.Invalid_aggressor "NOPE") -> true
                    | _ -> false)
                  errs
              in
              Alcotest.(check bool)
                "non-positive size reported" true has_non_positive_size;
              Alcotest.(check bool)
                "invalid aggressor reported" true has_invalid_aggressor
          | _ -> Alcotest.fail "expected a refusal");
      Gherkin.then_ "nothing is announced" (fun ctx ->
          Alcotest.(check int)
            "completed count" 0
            (List.length !(ctx.footprint_completed_pub)));
    ]

let feature =
  Gherkin.feature "Ingest print command"
    [
      first_print_opens_a_bar_silently;
      prints_in_the_same_bucket_stay_silent;
      crossing_into_the_next_bucket_announces_the_footprint;
      auction_volume_counts_without_moving_delta;
      a_late_print_is_ignored;
      malformed_print_is_refused;
    ]
