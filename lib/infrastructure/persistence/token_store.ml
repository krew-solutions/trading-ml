type t = { load : unit -> string option; save : string -> unit }

let load s = s.load ()
let save s v = s.save v

let env ~name =
  {
    load =
      (fun () ->
        match Sys.getenv_opt name with
        | Some v when v <> "" -> Some v
        | _ -> None);
    save = (fun _ -> ());
  }

let memory ?initial () =
  let r = ref initial in
  { load = (fun () -> !r); save = (fun v -> r := Some v) }

let file ~path =
  let load () =
    if not (Sys.file_exists path) then None
    else
      let content = In_channel.with_open_text path (fun ic -> In_channel.input_all ic) in
      Some (String.trim content)
  in
  let save v =
    let tmp = path ^ ".tmp" in
    Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc ] 0o600 tmp (fun oc ->
        Out_channel.output_string oc v);
    Sys.rename tmp path
  in
  { load; save }

let fallback primary secondary =
  {
    load =
      (fun () ->
        match primary.load () with
        | Some _ as v -> v
        | None -> secondary.load ());
    save = primary.save;
  }
