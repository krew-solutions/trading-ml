(** See [gbt_model.mli] for public contract. Only parser detail and
    split-traversal internals live here. *)

type objective = Regression | Binary | Multiclass of int

type tree = {
  (* Internal-node arrays, all same length = num_internal_nodes.
     Children: non-negative index → another internal node; negative
     value → leaf, decoded as [- child - 1]. *)
  split_feature : int array;
  threshold : float array;
  left_child : int array;
  right_child : int array;
  default_left : bool array;
  (* Leaf outputs, length = num_leaves = num_internal_nodes + 1. *)
  leaf_value : float array;
}

type t = {
  objective : objective;
  num_features : int;
  feature_names : string array;
  trees : tree array;
}

(* --- Tree traversal --- *)

let predict_tree (tree : tree) (features : float array) : float =
  let rec walk node =
    if node < 0 then tree.leaf_value.(-node - 1)
    else
      let f = tree.split_feature.(node) in
      let v = features.(f) in
      let goes_left =
        if Float.is_nan v then tree.default_left.(node) else v <= tree.threshold.(node)
      in
      walk (if goes_left then tree.left_child.(node) else tree.right_child.(node))
  in
  walk 0

let raw_score (m : t) ~features : float array =
  let k =
    match m.objective with
    | Regression | Binary -> 1
    | Multiclass k -> k
  in
  let scores = Array.make k 0.0 in
  Array.iteri
    (fun i tree ->
      let c = i mod k in
      scores.(c) <- scores.(c) +. predict_tree tree features)
    m.trees;
  scores

let sigmoid x = 1.0 /. (1.0 +. exp (-.x))

let softmax xs =
  let max_x = Array.fold_left Float.max Float.neg_infinity xs in
  let exps = Array.map (fun x -> exp (x -. max_x)) xs in
  let sum = Array.fold_left ( +. ) 0.0 exps in
  Array.map (fun e -> e /. sum) exps

let predict_class_probs m ~features =
  let raw = raw_score m ~features in
  match m.objective with
  | Regression -> invalid_arg "Gbt_model.predict_class_probs: regression objective"
  | Binary ->
      let p1 = sigmoid raw.(0) in
      [| 1.0 -. p1; p1 |]
  | Multiclass _ -> softmax raw

let predict m ~features =
  let raw = raw_score m ~features in
  match m.objective with
  | Regression -> raw.(0)
  | Binary -> sigmoid raw.(0)
  | Multiclass _ ->
      let probs = softmax raw in
      Array.fold_left Float.max probs.(0) probs

(* --- Parser for LightGBM native text format --- *)

(** Split a file into (header_lines, [tree_0_lines; tree_1_lines; ...]).
    Header = everything before the first line starting with "Tree=".
    Tree blocks end at the next "Tree=" or at "end of trees" /
    end-of-input. *)
let split_sections (lines : string list) : string list * string list list =
  let is_tree_marker l = String.length l >= 5 && String.sub l 0 5 = "Tree=" in
  let is_end l = l = "end of trees" in
  let header, rest =
    let rec go acc = function
      | [] -> (List.rev acc, [])
      | l :: _ as rest when is_tree_marker l -> (List.rev acc, rest)
      | l :: tl -> go (l :: acc) tl
    in
    go [] lines
  in
  let rec split_trees acc = function
    | [] -> List.rev acc
    | l :: _ when is_end l -> List.rev acc
    | header_line :: tl when is_tree_marker header_line ->
        let body, rest =
          let rec go b = function
            | [] -> (List.rev b, [])
            | l :: _ as rs when is_tree_marker l || is_end l -> (List.rev b, rs)
            | l :: rest -> go (l :: b) rest
          in
          go [] tl
        in
        split_trees ((header_line :: body) :: acc) rest
    | _ :: tl -> split_trees acc tl
  in
  (header, split_trees [] rest)

(** Parse "key=value" lines into a (key, value) assoc list. Lines
    without "=" are ignored. *)
let kv_of_lines (lines : string list) : (string * string) list =
  List.filter_map
    (fun l ->
      match String.index_opt l '=' with
      | None -> None
      | Some i ->
          let k = String.sub l 0 i in
          let v = String.sub l (i + 1) (String.length l - i - 1) in
          Some (String.trim k, String.trim v))
    lines

let find_key (kv : (string * string) list) (k : string) : string option =
  List.assoc_opt k kv

let require_key (kv : (string * string) list) (k : string) : string =
  match find_key kv k with
  | Some v -> v
  | None -> invalid_arg ("Gbt_model: missing required key: " ^ k)

let parse_int_array (s : string) : int array =
  if s = "" then [||]
  else
    String.split_on_char ' ' s
    |> List.filter (fun x -> x <> "")
    |> List.map int_of_string |> Array.of_list

let parse_float_array (s : string) : float array =
  if s = "" then [||]
  else
    String.split_on_char ' ' s
    |> List.filter (fun x -> x <> "")
    |> List.map float_of_string |> Array.of_list

let parse_string_array (s : string) : string array =
  if s = "" then [||]
  else String.split_on_char ' ' s |> List.filter (fun x -> x <> "") |> Array.of_list

(** Parse LightGBM's [objective=...] header value. Examples:
    - "regression" / "regression_l2"
    - "binary sigmoid:1"
    - "multiclass num_class:3" *)
let parse_objective (s : string) : objective =
  let first_word =
    match String.index_opt s ' ' with
    | Some i -> String.sub s 0 i
    | None -> s
  in
  match first_word with
  | "regression"
  | "regression_l1"
  | "regression_l2"
  | "huber"
  | "fair"
  | "poisson"
  | "quantile"
  | "mape"
  | "gamma"
  | "tweedie" -> Regression
  | "binary" -> Binary
  | "multiclass" | "multiclassova" | "softmax" ->
      (* Pull num_class:N from the remainder. *)
      let n =
        try Scanf.sscanf s "%s %s@:%d" (fun _ _ n -> n)
        with _ -> invalid_arg ("Gbt_model: cannot parse num_class in '" ^ s ^ "'")
      in
      if n < 2 then
        invalid_arg (Printf.sprintf "Gbt_model: multiclass needs num_class>=2, got %d" n);
      Multiclass n
  | other -> invalid_arg ("Gbt_model: unsupported objective: " ^ other)

(** LightGBM [decision_type] is a packed int8:
    - bit 0: 0 = [<=], 1 = [==] (categorical equality)
    - bit 1: 0 = default right, 1 = default left
    We reject categorical splits (bit 0 = 1); the [default_left]
    direction is what we return. *)
let default_left_of_decision_type (dt : int) : bool =
  if dt land 1 <> 0 then invalid_arg "Gbt_model: categorical split not supported"
  else dt land 2 <> 0

let parse_tree (lines : string list) : tree =
  let kv = kv_of_lines lines in
  (* Fail fast on features we don't implement. *)
  (match find_key kv "num_cat" with
  | Some s when int_of_string s > 0 ->
      invalid_arg "Gbt_model: categorical splits not supported"
  | _ -> ());
  (match find_key kv "is_linear" with
  | Some "1" -> invalid_arg "Gbt_model: linear tree leaves not supported"
  | _ -> ());
  let split_feature = parse_int_array (require_key kv "split_feature") in
  let threshold = parse_float_array (require_key kv "threshold") in
  let left_child = parse_int_array (require_key kv "left_child") in
  let right_child = parse_int_array (require_key kv "right_child") in
  let leaf_value = parse_float_array (require_key kv "leaf_value") in
  let decision_type = parse_int_array (require_key kv "decision_type") in
  let default_left = Array.map default_left_of_decision_type decision_type in
  (* Apply [shrinkage] if present — LightGBM stores learning-rate-scaled
     leaf values when [shrinkage != 1.0]. *)
  let shrinkage =
    match find_key kv "shrinkage" with
    | Some s -> float_of_string s
    | None -> 1.0
  in
  let leaf_value =
    if shrinkage = 1.0 then leaf_value else Array.map (fun v -> v *. shrinkage) leaf_value
  in
  (* Sanity-check array shapes. *)
  let n_int = Array.length split_feature in
  if
    Array.length threshold <> n_int
    || Array.length left_child <> n_int
    || Array.length right_child <> n_int
    || Array.length default_left <> n_int
  then invalid_arg "Gbt_model: tree internal-node arrays length mismatch";
  { split_feature; threshold; left_child; right_child; default_left; leaf_value }

let of_text (text : string) : t =
  let lines =
    String.split_on_char '\n' text
    |> List.map String.trim
    |> List.filter (fun l -> l <> "")
  in
  let header_lines, tree_blocks = split_sections lines in
  let kv = kv_of_lines header_lines in
  let objective = parse_objective (require_key kv "objective") in
  let num_features = int_of_string (require_key kv "max_feature_idx") + 1 in
  let feature_names =
    match find_key kv "feature_names" with
    | Some s -> parse_string_array s
    | None -> Array.init num_features (Printf.sprintf "f%d")
  in
  let trees = List.map parse_tree tree_blocks |> Array.of_list in
  { objective; num_features; feature_names; trees }

let of_file (path : string) : t =
  let content = In_channel.with_open_text path (fun ic -> In_channel.input_all ic) in
  of_text content

let file_mtime (path : string) : float option =
  try Some (Unix.stat path).st_mtime with _ -> None
