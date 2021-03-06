(*
Copyright (2010-2014) INCUBAID BVBA

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*)



open Lwt

type lwtoc = Lwt_io.output_channel
type lwtic = Lwt_io.input_channel

type namedValue =
  | NAMED_INT of string * int
  | NAMED_INT64 of string * int64
  | NAMED_FLOAT of string * float
  | NAMED_STRING of string * string
  | NAMED_VALUELIST of string * (namedValue list)

let named_value_info = function
  | NAMED_INT       (n, _i) -> n, 1
  | NAMED_INT64     (n, _i) -> n, 2
  | NAMED_FLOAT     (n, _f) -> n, 3
  | NAMED_STRING    (n, _s) -> n, 4
  | NAMED_VALUELIST (n, _l) -> n, 5

let lwt_failfmt fmt =
  let k x = Lwt.fail (Failure x) in
  Printf.ksprintf k fmt

type buffer = {buf : string ; mutable pos : int }
let make_buffer buf pos = {buf;pos}
let buffer_done b = b.pos = String.length b.buf
let buffer_pos b = b.pos

let buffer_set_pos b pos = b.pos <- pos

external get32_prim : string -> int -> int32 = "%caml_string_get32"
external set32_prim : string -> int -> int32 -> unit = "%caml_string_set32"
external get64_prim : string -> int -> int64 = "%caml_string_get64"
external set64_prim : string -> int -> int64 -> unit = "%caml_string_set64"

let int_from b =
  let result = get32_prim b.buf b.pos in
  let () = b.pos <- b.pos + 4 in
  Int32.to_int result

let int32_from b =
  let result = get32_prim b.buf b.pos in
  let () = b.pos <- b.pos + 4 in
  result

let int32_to buffer i32 =
  let s = String.create 4 in
  set32_prim s 0 i32;
  Buffer.add_string buffer s

let int_to buffer i = int32_to buffer (Int32.of_int i)

let int64_from b =
  let pos = b.pos
  and buf = b.buf
  in
  let r = get64_prim buf pos in
  let () = b.pos <- pos + 8 in
  r

let int64_to buf i64 =
  let s = String.create 8 in
  set64_prim s 0 i64;
  Buffer.add_string buf s


let output_int64 oc i64 =
  let s = String.create 8 in
  set64_prim s 0 i64;
  Lwt_io.write oc s

let input_int64 ic =
  let buf = String.create 8 in
  Lwt_io.read_into_exactly ic buf 0 8 >>= fun () ->
  let r = get64_prim buf 0 in
  Lwt.return r


let float_to buf f =
  let bf = Int64.bits_of_float f in
  int64_to buf bf

let float_from buffer =
  let bf = int64_from buffer in
  let f = Int64.float_of_bits bf in
  f



let string_from buffer =
  let size = int_from buffer in
  let pos = buffer.pos in
  let s = String.sub buffer.buf pos size in
  let () = buffer.pos <- pos + size in
  s

let string_to buffer s =
  let size = String.length s in
  int_to buffer size;
  Buffer.add_string buffer s

let char_to buffer c = Buffer.add_char buffer c

let char_from buffer =
  let pos = buffer.pos in
  let c = buffer.buf.[pos] in
  let () = buffer.pos <- pos + 1 in
  c


let bool_to buffer b =
  let c = if b then '\x01' else '\x00' in
  Buffer.add_char buffer c

let bool_from b =
  let p = b.pos in
  let c = b.buf.[p] in
  let r = match c with
    | '\x00' -> false
    | '\x01' -> true
    | _ -> failwith "not a boolean"
  in
  let () = b.pos <- p + 1 in
  r


let output_int32 oc (i:int32) =
  let s = String.create 4 in
  set32_prim s 0 i;
  Lwt_io.write oc s


let output_bool oc (b:bool) =
  let c = if b then '\x01' else '\x00' in
  Lwt_io.write_char oc c

let input_bool ic =
  Lwt_io.read_char ic >>= function
  | '\x00' -> Lwt.return false
  | '\x01' -> Lwt.return true
  | x -> lwt_failfmt "can't be a bool '%c'" x

let input_int32 ic =
  let buf = String.create 4 in
  Lwt_io.read_into_exactly ic buf 0 4 >>= fun () ->
  let r = get32_prim buf 0 in
  Lwt.return r


let output_int oc i =
  output_int32 oc (Int32.of_int i)

let input_int ic =
  Lwt.map Int32.to_int (input_int32 ic)

let output_string oc (s:string) =
  let size = String.length s in
  output_int32 oc (Int32.of_int size) >>= fun () ->
  Lwt_io.write oc s

let output_key oc (k:Key.t) =
  output_int32 oc (Int32.of_int (Key.length k)) >>= fun () ->
  Key.to_oc k oc

let input_string ic =
  input_int ic >>= fun size ->
  if size > (4 * 1024 * 1024 * 1024) then
    lwt_failfmt "Unexpectedly large string size requested:%d" size
  else Lwt.return size  >>= fun size2 ->
    let result = String.create size2 in
    Lwt_io.read_into_exactly ic result 0 size2 >>= fun () ->
    Lwt.return result

let output_string_pair oc (s0,s1) =
  output_string oc s0 >>= fun () ->
  output_string oc s1

let output_key_value_pair oc (k,v) =
  output_key oc k >>= fun () ->
  output_string oc v

let input_string_pair ic =
  input_string ic >>= fun s0 ->
  input_string ic >>= fun s1 ->
  Lwt.return (s0,s1)

let input_listl input_element ic =
  input_int ic >>= fun size ->
  let rec loop acc = function
    | 0 -> Lwt.return (size, acc)
    | i -> input_element ic >>= fun a -> loop (a :: acc) (i -1)
  in
  loop [] size

let input_list input_element ic =
  input_listl input_element ic >>= fun (size,list) ->
  Client_log.debug_f "Received a list of %d elements" size >>= fun () ->
  Lwt.return list

let input_string_list ic = input_list input_string ic

let input_kv_list ic = input_list input_string_pair ic

let _output_list output_element oc count list =
  output_int oc count >>= fun () ->
  Client_log.debug_f "Outputting list with %d elements" count >>= fun () ->
  Lwt_list.iter_s (output_element oc) list

let output_counted_list output_element oc (count, list) =
  _output_list output_element oc count list

let output_list output_element oc list =
  let count = List.length list in
  _output_list output_element oc count list

let output_string_list oc list = output_list output_string oc list

let output_kv_list oc = output_list output_string_pair oc

let output_array output_element oc es =
  let n = Array.length es in
  output_int oc n >>= fun () ->
  let rec loop i =
    if i = n
    then Lwt.return ()
    else
      begin
        let ei = es.(i) in
        output_element oc ei >>= fun () ->
        loop (i+1)
      end
  in
  loop 0

let output_array_reversed output_element oc es =
  let n = Array.length es in
  output_int oc n >>= fun () ->
  let rec loop i =
    if i < 0
    then Lwt.return ()
    else
      begin
        let ei = es.(i) in
        output_element oc ei >>= fun () ->
        loop (i-1)
      end
  in
  loop (n-1)

let output_string_array_reversed oc strings =
  output_array_reversed output_string oc strings

let list_to buf e_to list =
  int_to buf (List.length list);
  List.iter (e_to buf) (List.rev list)

let string_list_to buf sl = list_to buf string_to sl

let list_from b e_from  =
  let size = int_from b in
  let rec loop acc = function
    | 0 -> acc
    | i -> let e  = e_from b in
      loop (e::acc) (i-1)
  in loop [] size

let string_list_from buf = list_from buf string_from

let output_string_option oc = function
  | None -> output_bool oc false
  | Some s ->
    output_bool oc true >>= fun () ->
    output_string oc s

let option_to (f:Buffer.t -> 'a -> unit) buff =  function
  | None -> bool_to buff false
  | Some (v:'a) ->
    bool_to buff true;
    f buff v

let option_from (f:buffer -> 'a ) buffer =
  let b = bool_from buffer in
  match b with
    | false -> None
    | true -> let v = f buffer in
      Some v

let string_option_to buff so =  option_to string_to buff so

let string_option_from buffer = option_from string_from buffer



let input_string_option ic =
  input_bool ic >>= function
  | false -> Lwt.return None
  | true -> (input_string ic >>= fun s -> Lwt.return (Some s))

let hashtbl_to buf e2 h =
  let len = Hashtbl.length h in
  int_to buf len;
  Hashtbl.iter (fun k v -> e2 buf k v) h

let hashtbl_from buf ef =
  let len = int_from buf in
  let r = Hashtbl.create len in
  let rec loop = function
    | 0 -> r
    | i -> let (k,v) = ef buf in
      let () = Hashtbl.add r k v in
      loop (i-1)
  in
  loop len


let copy_stream ~length ~ic ~oc =
  Client_log.debug_f "copy_stream ~length:%Li" length >>= fun () ->
  let bs = Lwt_io.default_buffer_size () in
  let bs64 = Int64.of_int bs in
  let buffer = String.create bs in
  let n_bs = Int64.div length bs64 in
  let rest = Int64.to_int (Int64.rem length bs64) in
  let rec loop i =
    if i = Int64.zero
    then
      begin
        Lwt_io.read_into_exactly ic buffer 0 rest >>= fun () ->
        Lwt_io.write_from_exactly oc buffer 0 rest
      end
    else
      begin
        Lwt_io.read_into_exactly ic buffer 0 bs >>= fun () ->
        Lwt_io.write oc buffer >>= fun () ->
        loop (Int64.pred i)
      end
  in
  loop n_bs >>= fun () ->
  Client_log.debug "done: copy_stream"

let rec named_field_to (buffer: Buffer.t) (field: namedValue) : unit =
  let field_name, field_type = named_value_info field in
  int_to buffer field_type;
  string_to buffer field_name;
  match field with
    | NAMED_INT (_, i) ->
      int_to buffer i
    | NAMED_FLOAT (_, f) ->
      float_to buffer f
    | NAMED_INT64 (_, i) ->
      int64_to buffer i
    | NAMED_STRING (_, s) ->
      string_to buffer s
    | NAMED_VALUELIST (_, l) ->
      int_to buffer (List.length l);
      let encode_entry = named_field_to buffer in
      List.iter encode_entry l

let rec named_field_from buffer : namedValue =
  let field_type = int_from buffer in
  let field_name = string_from buffer in
  begin
    match field_type with
      | 1 ->
        let i = int_from buffer in
        NAMED_INT(field_name, i)
      | 2 ->
        let i64 = int64_from buffer in
        NAMED_INT64(field_name, i64)
      | 3 ->
        let f = float_from buffer in
        NAMED_FLOAT(field_name, f)
      | 4 ->
        let s = string_from buffer in
        NAMED_STRING(field_name, s)
      | 5 ->
        begin
          let rec decode_loop decoded = function
            | 0 -> (List.rev decoded)
            | i ->
              let new_elem = named_field_from buffer in
              decode_loop (new_elem :: decoded) (i-1)
          in
          let length  = int_from buffer in
          let decoded = decode_loop [] length in
          NAMED_VALUELIST(field_name, decoded)
        end
      | _ -> failwith "Unknown value type. Cannot decode."
  end

let input_hashtbl fk fv ic =
  input_int ic >>= fun elem_cnt ->
  let result = Hashtbl.create elem_cnt in
  let rec helper = function
    | 0 -> Lwt.return result
    | i ->
      begin
        fk ic >>= fun key ->
        fv ic >>= fun value ->
        Hashtbl.replace result key value;
        helper (i-1)
      end
  in
  helper elem_cnt

let output_hashtbl out_f oc ht =
  let l =  Hashtbl.length ht in
  output_int oc l >>= fun () ->
  let helper a b x =
    x >>= fun () ->
    out_f oc a b
  in
  Hashtbl.fold helper ht (Lwt.return ())
