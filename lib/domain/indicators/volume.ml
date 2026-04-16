(** Raw bar volume — a pass-through "indicator" so the server catalog
    exposes it to the UI alongside VolumeMA and the rest. The UI renders
    it as a histogram in the volume pane; on the OCaml side its value is
    simply the current bar's volume. *)

open Core

module M : Indicator.S = struct
  type state = { value : float option }
  type output = float

  let name = "Volume"

  let init () = { value = None }

  let update _ c =
    let v = Decimal.to_float c.Candle.volume in
    { value = Some v }, Some v

  let value st = st.value
  let output_to_float x = [x]
end

let make () = Indicator.make (module M)
