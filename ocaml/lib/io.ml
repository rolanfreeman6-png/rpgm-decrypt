(* Small binary file helpers: read a whole file into bytes, write bytes atomically. *)

let read_file (path : string) : bytes =
  In_channel.with_open_bin path In_channel.input_all |> Bytes.of_string

let write_file (path : string) (b : bytes) : unit =
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_bytes oc b)
