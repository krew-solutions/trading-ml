(** JSON encoders for the HTTP API. Per-resource projection goes
    through {!Queries.View_model.S} modules: domain value →
    [of_domain] → [yojson_of_t]. HTTP-response framing (the
    [{"candles": [...]}] wrappers, catalogs, catch-all shapes)
    stays here. *)

open Core
open Queries

(** Thin wrapper used for readability at call sites:
    [project Candle_view_model c] instead of a longer
    [Candle_view_model.yojson_of_t (Candle_view_model.of_domain c)]. *)
let project (type d) (module V : View_model.S with type domain = d) (x : d) :
    Yojson.Safe.t =
  V.yojson_of_t (V.of_domain x)

let candle_json (c : Candle.t) : Yojson.Safe.t = project (module Candle_view_model) c

let candles_json (cs : Candle.t list) : Yojson.Safe.t =
  `Assoc [ ("candles", `List (List.map candle_json cs)) ]

let indicators_catalog () : Yojson.Safe.t =
  `List
    (List.map
       (fun s ->
         `Assoc
           [
             ("name", `String s.Indicators.Registry.name);
             ( "params",
               `List
                 (List.map
                    (fun (k, p) ->
                      let kind, default =
                        match p with
                        | Indicators.Registry.Int n -> ("int", `Int n)
                        | Float f -> ("float", `Float f)
                      in
                      `Assoc
                        [
                          ("name", `String k); ("type", `String kind); ("default", default);
                        ])
                    s.Indicators.Registry.params) );
           ])
       Indicators.Registry.specs)

let strategies_catalog () : Yojson.Safe.t =
  `List
    (List.map
       (fun s ->
         `Assoc
           [
             ("name", `String s.Strategies.Registry.name);
             ( "params",
               `List
                 (List.map
                    (fun (k, p) ->
                      let kind, default =
                        match p with
                        | Strategies.Registry.Int n -> ("int", `Int n)
                        | Float f -> ("float", `Float f)
                        | Bool b -> ("bool", `Bool b)
                        | String s -> ("string", `String s)
                      in
                      `Assoc
                        [
                          ("name", `String k); ("type", `String kind); ("default", default);
                        ])
                    s.Strategies.Registry.params) );
           ])
       Strategies.Registry.specs)
