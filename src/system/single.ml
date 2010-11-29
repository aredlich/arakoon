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

open OUnit
open Lwt
open Node_cfg.Node_cfg
open Arakoon_remote_client
open Network
open Update


let should_fail x error_msg success_msg =
  Lwt.catch 
    (fun ()  -> 
      x () >>= fun () -> 
      Lwt_log.debug "should fail...doesn't" >>= fun () ->
      Lwt.return true) 
    (fun exn -> Lwt_log.debug ~exn success_msg >>= fun () -> Lwt.return false)
  >>= fun bad -> 
  if bad then Lwt.fail (Failure error_msg)
  else Lwt.return ()


let all_same_master ((cfgs,forced_master,quorum,_,_),_) =
  let masters = ref [] in
  let do_one cfg =
    Lwt_log.info_f "cfg:name=%s" (node_name cfg)  >>= fun () ->
    let f client =
      client # who_master () >>= function master ->
	masters := master :: !masters;
	Lwt.return ()
    in
    Client_main.with_client cfg f
  in
  Lwt_list.iter_s do_one cfgs >>= fun () ->
  assert_equal ~msg:"not all nodes were up"
    (List.length cfgs)
    (List.length !masters);
  let test = function
    | [] -> assert_failure "can't happen"
    | s :: rest ->
      begin
	List.iter
	  (fun s' ->
	    if s <> s' then assert_failure "different"
	    else match s with | None -> assert_failure "None" | _ -> ()
	  )
	  rest
      end
  in
  let () = test !masters in
  Lwt.return ()

let nothing_on_slave ((cfgs,forced_master,quorum,_, use_compression),_) =
  let find_slaves cfgs =
    Client_main.find_master cfgs >>= fun m ->
      let slave_cfgs = List.filter (fun cfg -> cfg.node_name <> m) cfgs in
	Lwt.return slave_cfgs
  in
  let named_fail name f =
    should_fail f
      (name ^ " should not succeed on slave")
      (name ^ " failed on slave, which is intended")
  in
  let set_on_slave client =
    named_fail "set" (fun () -> client # set "key" "value")
  in
  let delete_on_slave client =
    named_fail "delete" (fun () -> client # delete "key")
  in
  let test_and_set_on_slave client =
    named_fail "test_and_set"
      (fun () ->
	let wanted = Some "value!" in
	 client # test_and_set "key" None wanted >>= fun _ ->
	   Lwt.return ()
      )
  in
  let test_slave cfg =
    Lwt_log.info_f "slave=%s" cfg.node_name  >>= fun () ->
      let f client =
	set_on_slave client >>= fun () ->
        delete_on_slave client >>= fun () ->
	test_and_set_on_slave client
      in
	Client_main.with_client cfg f
  in
  let test_slaves cfgs =
    find_slaves cfgs >>= fun slave_cfgs ->
      let rec loop = function
	| [] -> Lwt.return ()
	| cfg :: rest -> test_slave cfg >>= fun () ->
	    loop rest
      in loop slave_cfgs
  in
  test_slaves cfgs


let _get_after_set client =
  client # set "set" "some_value" >>= fun () ->
  client # get "set" >>= fun value ->
  if value <> "some_value"
  then Llio.lwt_failfmt "\"%S\" <> \"some_value\"" value
  else Lwt.return ()

let _exists client =
  client # set "Geronimo" "Stilton" >>= fun () ->
  client # exists "Geronimo" >>= fun yes ->
  client # exists "Mickey" >>= fun no ->
  begin
    if yes
    then Lwt_log.info_f "exists yields true, which was expected"
    else Llio.lwt_failfmt "Geronimo should be in there"
  end >>= fun () ->
  begin
    if no then
      Llio.lwt_failfmt "Mickey should not be in there"
    else
      Lwt_log.info_f" Mickey's not in there, as expected"
  end

let _delete_after_set client =
  let key = "_delete_after_set" in
  client # set key "xxx" >>= fun () ->
  client # delete key    >>= fun () ->
  should_fail
    (fun () ->
      client # get "delete"  >>= fun v ->
      Lwt_log.info_f "delete_after_set get yields value=%S" v >>= fun () ->
      Lwt.return ()
    )
    "get after delete yields, which is A PROBLEM!"
    "get after delete fails, which was intended"

let _test_and_set_1 (client:Arakoon_client.client) =
  Lwt_log.info_f "_test_and_set_1" >>= fun () ->
  let wanted_s = "value!" in
  let wanted = Some wanted_s in
  client # test_and_set "test_and_set" None wanted >>= fun result ->
    begin
      match result with
	| None -> Llio.lwt_failfmt "result should not be None"
	| Some v ->
	  if v <> wanted_s
	  then
	    Lwt_log.info_f "value=%S, and should be '%s'" v wanted_s
	     >>= fun () ->
	  Llio.lwt_failfmt "different value"
	  else Lwt_log.info_f "value=%S, is what we expected" v
    end >>= fun () -> (* clean up *)
  client # delete "test_and_set" >>= fun () ->
  Lwt.return ()


let _test_and_set_2 (client: Arakoon_client.client) =
  Lwt_log.info_f "_test_and_set_2" >>= fun () ->
  let wanted = Some "wrong!" in
  client # test_and_set "test_and_set" (Some "x") wanted
  >>= fun result ->
  begin
    match result with
      | None -> Lwt_log.info_f "value is None, which is intended"
      | Some x -> Llio.lwt_failfmt "value='%S', which is unexpected" x
  end >>= fun () ->
  Lwt.return ()

let _test_and_set_3 (client: Arakoon_client.client) = 
  Lwt_log.info_f "_test_and_set_3" >>= fun () ->
  let key = "_test_and_set_3" in
  let value = "bla bla" in
  client # set key value >>= fun () ->
  client # test_and_set key (Some value) None >>= fun result ->
  begin 
    if result <> None then Llio.lwt_failfmt "should have been None" 
    else 
      begin
	client # exists key >>= fun b -> 
	if b then
	  Llio.lwt_failfmt "we should have deleted this"
	else Lwt.return ()
      end
  end
  

let _range_1 (client: Arakoon_client.client) =
  Lwt_log.info_f "_range_1" >>= fun () ->
  let rec fill i =
    if i = 100
    then Lwt.return ()
    else
      let key = "range_" ^ (string_of_int i)
      and value = (string_of_int i) in
      client # set key value >>= fun () -> fill (i+1)
  in fill 0 >>= fun () ->
  client # range (Some "range_1") true (Some "rs") true 10 >>= fun keys ->
  let size = List.length keys in
  Lwt_log.info_f "size = %i" size >>= fun () ->
  if size <> 10
  then Llio.lwt_failfmt "size should be 10 and is %i" size
  else Lwt.return ()

let _range_entries_1 (client: Arakoon_client.client) =
  Lwt_log.info_f "_range_entries_1" >>= fun () ->
  let rec fill i =
    if i = 100
    then Lwt.return ()
    else
      let key = "range_entries_" ^ (string_of_int i)
      and value = (string_of_int i) in
      client # set key value >>= fun () -> fill (i+1)
  in fill 0 >>= fun () ->
  client # range_entries (Some "range_entries") true (Some "rs") true 10 >>= fun keys ->
  let size = List.length keys in
  Lwt_log.info_f "size = %i" size >>= fun () ->
  if size <> 10
  then Llio.lwt_failfmt "size should be 10 and is %i" size
  else Lwt.return ()

let _detailed_range client =
  Lwt_log.info_f "_detailed_range" >>= fun () ->
  Arakoon_remote_client_test._test_range client

let _prefix_keys (client:Arakoon_client.client) =
  Lwt_log.info_f "_prefix_keys" >>= fun () ->
  Arakoon_remote_client_test._prefix_keys_test client

(* TODO: nodestream test 
let _list_entries (client:Nodestream.nodestream) =
  Lwt_log.info_f "_list_entries" >>= fun () ->
  let filename = "/tmp/_list_entries.tlog" in
  Lwt_io.with_file filename ~mode:Lwt_io.output
    (fun oc ->
      let f (i,update) = Lwt.return () in
      client # iterate Sn.start f)
*)
let _sequence (client: Arakoon_client.client) =
  Lwt_log.info_f "_sequence" >>= fun () ->
  client # set "XXX0" "YYY0" >>= fun () ->
  let updates = [Arakoon_client.Set("XXX1","YYY1");
		 Arakoon_client.Set("XXX2","YYY2");
		 Arakoon_client.Set("XXX3","YYY3");
		 Arakoon_client.Delete "XXX0";
		]
  in
  client # sequence updates >>= fun () ->
  client # get "XXX1" >>= fun v1 ->
  OUnit.assert_equal v1 "YYY1";
  client # get "XXX2" >>= fun v2 ->
  OUnit.assert_equal v2 "YYY2";
  client # get "XXX3">>= fun v3 ->
  OUnit.assert_equal v3 "YYY3";
  client # exists "XXX0" >>= fun exists ->
  OUnit.assert_bool "XXX0 should not be there" (not exists);
  Lwt.return ()

let _sequence2 (client: Arakoon_client.client) = 
  Lwt_log.info_f "_sequence" >>= fun () ->
  let k1 = "I_DO_NOT_EXIST" in
  let k2 = "I_SHOULD_NOT_EXIST" in
  let updates = [
    Arakoon_client.Delete(k1);
    Arakoon_client.Set(k2, "REALLY")
  ]
  in
  should_fail
    (fun () -> client # sequence updates)
    "_sequence2:failing delete in sequence does not produce exception" 
    "_sequence2:produced exception, which is intended"
  >>= fun ()->
  Lwt_log.debug "_sequence2: part 2 of scenario" >>= fun () ->
  should_fail 
    (fun () -> client # get k2 >>= fun _ -> Lwt.return ())
    "PROBLEM:_sequence2: get yielded a value" 
    "_sequence2: ok, this get should indeed fail"
  >>= fun () -> Lwt.return ()

let _sequence3 (client: Arakoon_client.client) = 
  Lwt_log.info_f "_sequence3" >>= fun () ->
  let k1 = "sequence3:key1" 
  and k2 = "sequence3:key2" 
  in
  let changes = [Arakoon_client.Set (k1,k1 ^ ":value"); 
		 Arakoon_client.Delete k2;] in 
  should_fail 
    (fun () -> client # sequence changes) 
    "PROBLEM: _sequence3: change should fail (exception in change)" 
    "sequence3 changes indeed failed"
  >>= fun () ->
  should_fail 
    (fun () -> client # get k1 >>= fun v1 -> Lwt_log.info_f "value=:%s" v1)
    "PROBLEM:changes should be all or nothing" 
    "ok: all-or-noting changes"
  >>= fun () -> Lwt_log.info_f "sequence3.ok"

let trivial_master ((cfgs,forced_master,quorum,_, use_compression),_) =
  Client_main.find_master cfgs >>= fun master_name ->
  Lwt_log.info_f "master=%S" master_name >>= fun () ->
  let master_cfg =
    List.hd (List.filter (fun cfg -> cfg.node_name = master_name) cfgs)
  in
  let f client =
    _get_after_set client >>= fun () ->
    _delete_after_set client >>= fun () ->
    _exists client >>= fun () ->
    _test_and_set_1 client >>= fun () ->
    _test_and_set_2 client >>= fun () ->
    _test_and_set_3 client 
  in
  Client_main.with_client master_cfg f

let trivial_master2 ((cfgs,forced_master,quorum,_, use_compression),_) =
  
Client_main.find_master cfgs >>= fun master_name ->
  Lwt_log.info_f "master=%S" master_name >>= fun () ->
  let master_cfg =
    List.hd (List.filter (fun cfg -> cfg.node_name = master_name) cfgs)
  in
  let f client =
    _test_and_set_3 client >>= fun () ->
    _range_1 client >>= fun () ->
    _range_entries_1 client >>= fun () ->
    _prefix_keys client >>= fun () ->
    _detailed_range client 
  in
  Client_main.with_client master_cfg f


let trivial_master3 ((cfgs,forced_master,quorum,_, use_compression),_) =
  Client_main.find_master cfgs >>= fun master_name ->
  Lwt_log.info_f "master=%S" master_name >>= fun () ->
  let master_cfg =
    List.hd (List.filter (fun cfg -> cfg.node_name = master_name) cfgs)
  in
  let f client =
    _sequence client >>= fun () ->
    _sequence2 client >>= fun () ->
    _sequence3 client 
  in
  Client_main.with_client master_cfg f

let setup () =
  let cfgs,forced_master, quorum, lease_expiry, use_compression = 
    read_config "cfg/arakoon.ini" in
  Lwt.return ((cfgs, forced_master, quorum, lease_expiry, use_compression), ())

let teardown (_,()) =
  Lwt.return ()

let client_suite =
  let w f = Extra.lwt_bracket setup f teardown in
  "single" >:::
    [
      "all_same_master" >:: w all_same_master;
      "nothing_on_slave" >:: w nothing_on_slave;
      "trivial_master" >:: w trivial_master;
    ]

let setup master () =
  let lease_period = 60 in
  let make_config () = Node_cfg.Node_cfg.make_test_config 3 master lease_period in
  let t0 = Node_main.test_t make_config "t_arakoon_0" in
  let t1 = Node_main.test_t make_config "t_arakoon_1" in
  let t2 = Node_main.test_t make_config "t_arakoon_2" in
  let j = Lwt.catch (fun () -> Lwt.join [t0;t1;t2;])
    (fun e ->
      Lwt_log.info_f "XXX error in node: %s" (Printexc.to_string e) >>= fun () ->
      Lwt.fail e
    )
  in
  let () = Lwt.ignore_result j in
  Lwt_unix.sleep 0.7 >>= fun () ->
  Lwt.return (make_config (), j)

let teardown (_, j) =
  Lwt_log.info_f "cancelling j" >>= fun () ->
  let () = Lwt.cancel j in
  Lwt.return ()

let force_master =
  let w f = Extra.lwt_bracket (setup (Some "t_arakoon_0")) f teardown in
  "force_master" >:::
    [
      "all_same_master" >:: w all_same_master;
      "nothing_on_slave" >:: w nothing_on_slave;
      "trivial_master" >:: w trivial_master;
      "trivial_master2" >:: w trivial_master2;
      "trivial_master3" >:: w trivial_master3;
    ]

let elect_master =
  let w f = Extra.lwt_bracket (setup None) f teardown in
  "elect_master" >:::
    [
      "all_same_master" >:: w all_same_master;
      "nothing_on_slave" >:: w nothing_on_slave;
      "trivial_master" >:: w trivial_master;
      "trivial_master2" >:: w trivial_master2;
      "trivial_master3" >:: w trivial_master3;
    ]
