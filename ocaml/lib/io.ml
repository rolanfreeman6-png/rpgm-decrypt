(* Small binary file helpers (F# used File.ReadAllBytes / WriteAllBytes inline). *)

let read_file (path : string) : bytes =
  In_channel.with_open_bin path In_channel.input_all |> Bytes.of_string

let write_file (path : string) (b : bytes) : unit =
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_bytes oc b)
