(** Minimal logistic regression: sigmoid, prediction, and online SGD.
    No external dependencies — pure float arithmetic.

    The model is a single-layer linear classifier:
      P(y=1 | x) = sigmoid(bias + Σ wᵢ·xᵢ)

    Training uses stochastic gradient descent with optional L2
    regularisation (weight decay) to mitigate overfitting on the
    small sample sizes typical of per-instrument strategy history. *)

type t = {
  weights : float array;  (** [|bias; w₁; w₂; …|] — length = 1 + n_features *)
  lr : float;  (** learning rate *)
  l2 : float;  (** L2 regularisation coefficient (weight decay) *)
}

let make ~n_features ?(lr = 0.01) ?(l2 = 1e-4) () =
  { weights = Array.make (1 + n_features) 0.0; lr; l2 }

let n_features t = Array.length t.weights - 1

let sigmoid z =
  if z > 15.0 then 1.0 else if z < -15.0 then 0.0 else 1.0 /. (1.0 +. exp (-.z))

let predict t (features : float array) : float =
  let z = ref t.weights.(0) in
  let n = min (Array.length features) (n_features t) in
  for i = 0 to n - 1 do
    z := !z +. (t.weights.(i + 1) *. features.(i))
  done;
  sigmoid !z

(** One SGD step: update weights given a single (features, target)
    observation. [target] is 0.0 or 1.0. *)
let sgd_step t (features : float array) (target : float) : unit =
  let pred = predict t features in
  let err = pred -. target in
  t.weights.(0) <- t.weights.(0) -. (t.lr *. err);
  let n = min (Array.length features) (n_features t) in
  for i = 0 to n - 1 do
    let grad = (err *. features.(i)) +. (t.l2 *. t.weights.(i + 1)) in
    t.weights.(i + 1) <- t.weights.(i + 1) -. (t.lr *. grad)
  done

(** Train on a dataset [(features, target) list] for [epochs] passes.
    Returns the final log-loss on the last epoch (for diagnostics). *)
let train t ~epochs (data : (float array * float) list) : float =
  let log_loss pred target =
    let p = Float.max 1e-12 (Float.min (1.0 -. 1e-12) pred) in
    -.((target *. log p) +. ((1.0 -. target) *. log (1.0 -. p)))
  in
  let loss = ref 0.0 in
  for _ = 1 to epochs do
    loss := 0.0;
    List.iter
      (fun (features, target) ->
        loss := !loss +. log_loss (predict t features) target;
        sgd_step t features target)
      data
  done;
  match data with
  | [] -> 0.0
  | _ -> !loss /. float_of_int (List.length data)

(** Copy the learned weights into a fresh array (for serialisation
    or embedding into a [Composite.Learned] params). *)
let export_weights t : float array = Array.copy t.weights

(** Restore from a weight vector (e.g. loaded from config). *)
let of_weights ?(lr = 0.01) ?(l2 = 1e-4) weights =
  { weights = Array.copy weights; lr; l2 }

let to_json (t : t) : Yojson.Safe.t =
  `Assoc
    [
      ("weights", `List (Array.to_list t.weights |> List.map (fun f -> `Float f)));
      ("lr", `Float t.lr);
      ("l2", `Float t.l2);
    ]

let float_of_json = function
  | `Float f -> f
  | `Int n -> float_of_int n
  | j ->
      invalid_arg
        ("Logistic.float_of_json: expected number, got " ^ Yojson.Safe.to_string j)

let of_json (j : Yojson.Safe.t) : t =
  let open Yojson.Safe.Util in
  let weights =
    match member "weights" j with
    | `List xs -> List.map float_of_json xs |> Array.of_list
    | _ -> invalid_arg "Logistic.of_json: missing or non-array [weights]"
  in
  let read_float_or default k =
    match member k j with
    | `Null -> default
    | other -> float_of_json other
  in
  let lr = read_float_or 0.01 "lr" in
  let l2 = read_float_or 1e-4 "l2" in
  { weights; lr; l2 }

let to_file ~path t =
  let tmp = path ^ ".tmp" in
  Out_channel.with_open_text tmp (fun oc ->
      Out_channel.output_string oc (Yojson.Safe.pretty_to_string (to_json t)));
  Sys.rename tmp path

let of_file path =
  let content = In_channel.with_open_text path In_channel.input_all in
  of_json (Yojson.Safe.from_string content)
