(*
This file is part of Arakoon, a distributed key-value store. Copyright
(C) 2010 Incubaid BVBA

Licensees holding a valid Incubaid license may use this file in
accordance with Incubaid's Arakoon commercial license agreement. For
more information on how to enter into this agreement, please contact
Incubaid (contact details can be found on www.arakoon.org/licensing).

Alternatively, this file may be redistributed and/or modified under
the terms of the GNU Affero General Public License version 3, as
published by the Free Software Foundation. Under this license, this
file is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.

See the GNU Affero General Public License for more details.
You should have received a copy of the
GNU Affero General Public License along with this program (file "COPYING").
If not, see <http://www.gnu.org/licenses/>.
*)

open Mp_msg
open Lwt
open Update
open Routing
open Log_extra
open Store
open Unix.LargeFile


module B = Camltc.Bdb

let _get bdb key = B.get bdb key

let _set bdb key value = B.put bdb key value

let _delete bdb key    = B.out bdb key

let _delete_prefix bdb prefix =
  B.delete_prefix bdb prefix

let _range_entries _pf bdb first finc last linc max =
  let keys_array = B.range bdb (_f _pf first) finc (_l _pf last) linc max in
  let keys_list = Array.to_list keys_array in
  let pl = String.length _pf in
  let x = List.fold_left
    (fun ret_list k ->
      let l = String.length k in
      ((String.sub k pl (l-pl)), B.get bdb k) :: ret_list )
    []
    keys_list
  in x

let copy_store old_location new_location overwrite =
  File_system.exists old_location >>= fun src_exists ->
  if not src_exists
  then
    Lwt_log.debug_f "File at %s does not exist" old_location >>= fun () ->
    raise Not_found
  else
  begin
    File_system.exists new_location >>= fun dest_exists ->
    begin
      if dest_exists && overwrite
      then
        Lwt_unix.unlink new_location
      else
        Lwt.return ()
    end >>= fun () ->
    begin
      if dest_exists && not overwrite
      then
        Lwt_log.debug_f "Not relocating store from %s to %s, destination exists" old_location new_location
      else
        File_system.copy_file old_location new_location
    end
  end

let get_construct_params db_name ~mode=
  Camltc.Hotc.create db_name ~mode >>= fun db ->
  Lwt.return db

class local_store (db_location:string) (db:Camltc.Hotc.t) =

object(self: #simple_store)
  val mutable my_location = db_location
  val mutable _closed = false (* set when close method is called *)
  val mutable _tx = None
  val mutable _tx_lock = None
  val _tx_lock_mutex = Lwt_mutex.create ()

  method is_closed () =
    _closed

  method private _with_tx : 'a. transaction -> (Camltc.Hotc.bdb -> 'a) -> 'a =
    fun tx f ->
      match _tx with
        | None -> failwith "not in a transaction"
        | Some (tx', db) ->
            if tx != tx'
            then
              failwith "the provided transaction is not the current transaction of the store"
            else
              f db

  method with_transaction_lock f =
    Lwt_mutex.with_lock _tx_lock_mutex (fun () ->
      Lwt.finalize
        (fun () ->
          let txl = new transaction_lock in
          _tx_lock <- Some txl;
          f txl)
        (fun () -> _tx_lock <- None; Lwt.return ()))

  method with_transaction ?(key=None) f =
    let matched_locks = match _tx_lock, key with
      | None, None -> true
      | Some txl, Some txl' -> txl == txl'
      | _ -> false in
    if not matched_locks
    then failwith "transaction locks do not match";
    let t0 = Unix.gettimeofday() in
    Lwt.finalize
      (fun () ->
        Camltc.Hotc.transaction db
          (fun db ->
            let tx = new transaction in
            _tx <- Some (tx, db);
            f tx >>= fun a ->
            Lwt.return a))
      (fun () ->
        let t = ( Unix.gettimeofday() -. t0) in
        if t > 1.0
        then
          Lwt_log.info_f "Tokyo cabinet transaction took %fs" t
        else
          Lwt.return (); >>= fun () ->
        _tx <- None; Lwt.return ())

  method optimize quiesced =
    let db_optimal = my_location ^ ".opt" in
    Lwt_log.debug "Copying over db file" >>= fun () ->
    Lwt_io.with_file
        ~flags:[Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC]
        ~mode:Lwt_io.output
        db_optimal (fun oc -> self # copy_store ~_networkClient:false oc )
    >>= fun () ->
    begin 
      Lwt_log.debug_f "Creating new db object at location %s" db_optimal >>= fun () ->
      Camltc.Hotc.create db_optimal >>= fun db_opt ->
      Lwt.finalize
      ( fun () ->
        Lwt_log.info "Optimizing db copy" >>= fun () ->
        Camltc.Hotc.optimize db_opt >>= fun () ->
        Lwt_log.info "Optimize db copy complete"
      ) 
      ( fun () ->
        Camltc.Hotc.close db_opt
      )
    end >>= fun () ->
    File_system.rename db_optimal my_location >>= fun () ->
    self # reopen (fun () -> Lwt.return ()) quiesced

  method defrag() = 
    Lwt_log.debug "local_store :: defrag" >>= fun () ->
    Camltc.Hotc.defrag db >>= fun rc ->
    Lwt_log.debug_f "local_store %s :: defrag done: rc=%i" db_location rc>>= fun () ->
    Lwt.return ()

  (*method private open_db () =
    Hotc._open_lwt db *)

  method exists key =
    let bdb = Camltc.Hotc.get_bdb db in
    B.exists bdb key

  method get key =
    let bdb = Camltc.Hotc.get_bdb db in
    B.get bdb key

  method range prefix first finc last linc max =
    let bdb = Camltc.Hotc.get_bdb db in
    let r = B.range bdb (_f prefix first) finc (_l prefix last) linc max in
    filter_keys_array r

  method range_entries prefix first finc last linc max =
    let bdb = Camltc.Hotc.get_bdb db in
    let r = _range_entries prefix bdb (_f prefix first) finc (_l prefix last) linc max in
    r

  method rev_range_entries prefix first finc last linc max =
    let bdb = Camltc.Hotc.get_bdb db in
    let r = B.rev_range_entries prefix bdb (_f prefix first) finc (_l prefix last) linc max in
    r

  method prefix_keys prefix max =
    let bdb = Camltc.Hotc.get_bdb db in
    let keys_array = B.prefix_keys bdb prefix max in
	let keys_list = filter_keys_array keys_array in
	Lwt.return keys_list

  method set tx key value =
    self # _with_tx tx (fun db -> _set db key value)

  method delete tx key =
    self # _with_tx tx (fun db -> _delete db key)

  method delete_prefix tx ?(_pf=__prefix) prefix =
    self # _with_tx tx
      (fun db -> _delete_prefix db prefix)

  method close () =
    _closed <- true;
    Camltc.Hotc.close db >>= fun () ->  
    Lwt_log.info_f "local_store %S :: closed  () " db_location >>= fun () ->
    Lwt.return ()

  method get_location () = Camltc.Hotc.filename db

  method reopen f quiesced =
    let mode =
    begin
      if quiesced then
        B.readonly_mode
      else
        B.default_mode
    end in
    Lwt_log.debug_f "local_store %S::reopen calling Hotc::reopen" db_location >>= fun () ->
    Camltc.Hotc.reopen db f mode >>= fun () ->
    Lwt_log.debug "local_store::reopen Hotc::reopen succeeded"

  method get_key_count () =
    Lwt_log.debug "local_store::get_key_count" >>= fun () ->
    Camltc.Hotc.transaction db (fun db -> Lwt.return ( B.get_key_count db ) )

  method copy_store ?(_networkClient=true) (oc: Lwt_io.output_channel) =
    let db_name = my_location in
    let stat = Unix.LargeFile.stat db_name in
    let length = stat.st_size in
    Lwt_log.debug_f "store:: copy_store (filesize is %Li bytes)" length >>= fun ()->
    begin
      if _networkClient 
      then
        Llio.output_int oc 0 >>= fun () ->
      Llio.output_int64 oc length 
      else Lwt.return ()
    end
    >>= fun () ->
    Lwt_io.with_file
      ~flags:[Unix.O_RDONLY]
      ~mode:Lwt_io.input
      db_name (fun ic -> Llio.copy_stream ~length ~ic ~oc)
    >>= fun () ->
    Lwt_io.flush oc

  method relocate new_location =
    copy_store my_location new_location true >>= fun () ->
    let old_location = my_location in
    let () = my_location <- new_location in
    Lwt_log.debug_f "Attempting to unlink file '%s'" old_location >>= fun () ->
    File_system.unlink old_location >>= fun () ->
    Lwt_log.debug_f "Successfully unlinked file at '%s'" old_location


  method get_fringe border direction =
    let cursor_init, get_next, key_cmp =
      begin
        match direction with
        | Routing.UPPER_BOUND ->
          let skip_keys lcdb cursor =
            let () = B.first lcdb cursor in
            let rec skip_admin_key () =
              begin
                let k = B.key lcdb cursor in
                if k.[0] <> __adminprefix.[0]
                then
                  Lwt.ignore_result ( Lwt_log.debug_f "Not skipping key: %s" k )
                else
                  begin
                    Lwt.ignore_result ( Lwt_log.debug_f "Skipping key: %s" k );
                    begin
                      try
                        B.next lcdb cursor;
                        skip_admin_key ()
                      with Not_found -> ()
                    end
                  end
              end
            in
            skip_admin_key ()
          in
          let cmp =
            begin
              match border with
                | Some b ->  (fun k -> k >= (__prefix ^ b))
                | None -> (fun k -> false)
            end
          in
          skip_keys, B.next, cmp
        | Routing.LOWER_BOUND ->
          let cmp =
            begin
              match border with
                | Some b -> (fun k -> k < (__prefix ^ b) or k.[0] <> __prefix.[0])
                | None -> (fun k -> k.[0] <> __prefix.[0])
            end
          in
          B.last, B.prev, cmp
      end
    in
    Lwt_log.debug_f "local_store::get_fringe %S" (Log_extra.string_option2s border) >>= fun () ->
    let buf = Buffer.create 128 in
    Lwt.finalize
      (fun () ->
        Camltc.Hotc.transaction db
          (fun txdb ->
            Camltc.Hotc.with_cursor txdb
            (fun lcdb cursor ->
              Buffer.add_string buf "1\n";
              let limit = 1024 * 1024 in
              let () = cursor_init lcdb cursor in
              Buffer.add_string buf "2\n";
              let r =
                let rec loop acc ts =
                  begin
                    try
                      let k = B.key   lcdb cursor in
                      let v = B.value lcdb cursor in
                      if ts >= limit  or (key_cmp k)
                      then acc
                      else
                        let pk = String.sub k 1 (String.length k -1) in
                        let acc' = (pk,v) :: acc in
                        Buffer.add_string buf (Printf.sprintf "pk=%s v=%s\n" pk v);
                        let ts' = ts + String.length k + String.length v in
                        begin
                          try
                            get_next lcdb cursor ;
                            loop acc' ts'
                          with Not_found ->
                            acc'
                        end
                    with Not_found ->
                      acc
                  end

              in
              loop [] 0
              in
              Lwt.return r
            )
          )
      )
      (fun () ->
        Lwt_log.debug_f "buf:%s" (Buffer.contents buf)
    )
end

let make_local_store ?(read_only=false) db_name =
  let mode =
    if read_only
    then B.readonly_mode
    else B.default_mode
  in
  Lwt_log.debug_f "Creating local store at %s" db_name >>= fun () ->
  get_construct_params db_name ~mode
  >>= fun db ->
  let store = new local_store db_name db in
  Lwt.return (make_store (store :> simple_store))
