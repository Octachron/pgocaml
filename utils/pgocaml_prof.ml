(* A tool to analyse profiling traces generated by $PGPROFILING=filename.
 * See README.profiling for more information.
 *
 * PG'OCaml - type safe interface to PostgreSQL.
 * Copyright (C) 2005-2009 Richard Jones and other authors.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this library; see the file COPYING.  If not, write to
 * the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
 * Boston, MA 02111-1307, USA.
 *)

open Printf
module Option = BatOption

let (//) = Filename.concat

(* Don't keep the rows in memory, instead divide them by connection
 * and write into a temporary directory.  This allows us to handle
 * very large profiles.
 *)
let tmpdir = Filename.temp_file "pgocamlprof" ".d"
let nr_rows = ref 0
let () =
  (* Filename.temp_file actually creates the file - delete it. *)
  (try Unix.unlink tmpdir with _ -> ());
  Unix.mkdir tmpdir 0o755;

  (* Little bit of caching helps in the common case where adjacent
   * rows belong to the same connection.
   *)
  let get_chan, close_chan =
    let last_conn = ref None in
    let last_chan = ref None in
    let close_chan () =
      match !last_chan with
      | None -> ()
      | Some chan ->
	  close_out chan;
	  last_chan := None;
	  last_conn := None
    in
    let get_chan conn =
      match !last_conn with
      | Some conn' when conn = conn' -> Option.get !last_chan
      | _ ->
	  close_chan ();
	  let open_flags = [ Open_wronly; Open_append; Open_creat ] in
	  let filename = tmpdir // conn in
	  let chan = open_out_gen open_flags 0o644 filename in
	  last_chan := Some chan;
	  last_conn := Some conn;
	  chan
    in
    get_chan, close_chan in

  let f = function
    | ("1" as version) :: conn :: rest ->
	let chan = get_chan conn in
	incr nr_rows;
	Csv.save_out chan [version :: rest];

    | _ -> () (* just ignore versions we don't understand *)
  in

  let chan = open_in Sys.argv.(1) in
  Csv.load_rows f chan;
  close_in chan;

  (* Close the cached out_channel. *)
  close_chan ()

(* Accumulate results by query and by connection.
 * (Implicitly assume that queries can be treated independently.)
 *)
type query_data = {
  query : string;			(* Query (prepared, w/placeholders). *)
  qprogs : string list;			(* Programs which used this. *)
  nr_preps : int;			(* Number of times prepared. *)
  prep_time : int;			(* Total prep time (ms). *)
  nr_execs : int;			(* Number of times executed. *)
  exec_time : int;			(* Total exec time (ms). *)
  nr_qfailures : int;			(* Number of failures (prep+exec). *)
}
let queries = Hashtbl.create 31
let set_query query update =
  let data =
    try Hashtbl.find queries query
    with Not_found ->
      { query = query; qprogs = []; nr_preps = 0; prep_time = 0;
	nr_execs = 0; exec_time = 0; nr_qfailures = 0 } in
  let data = update data in
  Hashtbl.replace queries query data

type connection_data = {
  params : connection_params;		(* Connection parameters. *)
  progs : string list;			(* Programs which used this. *)
  nr_connects : int;			(* Number of connects. *)
  connect_time : int;			(* Total connect time (ms). *)
  nr_closes : int;			(* Number of explicit closes. *)
  close_time : int;			(* Total close time (ms). *)
  nr_pings : int;			(* Number of pings. *)
  ping_time : int;			(* Total ping time (ms). *)
  nr_failures : int;			(* Number of failures. *)
}
and connection_params = {
  user : string;
  database : string;
  host : string;
  port : int;
}
let connections = Hashtbl.create 31
let set_connection params update =
  let data =
    try Hashtbl.find connections params
    with Not_found ->
      { params = params; progs = []; nr_connects = 0; connect_time = 0;
	nr_closes = 0; close_time = 0; nr_pings = 0; ping_time = 0;
	nr_failures = 0; } in
  let data = update data in
  Hashtbl.replace connections params data

exception Ignore of string

let files = Array.to_list (Sys.readdir tmpdir)
let nr_rows' = ref 0

let () =
  List.iter (
    fun uuid ->
      let rows = Csv.load (tmpdir // uuid) in
      nr_rows' := !nr_rows' + (List.length rows);

      let ignore msg = raise (Ignore msg) in
      try
	assert (rows <> []);

	let rec assoc i =
	  function
	  | x :: y :: xs when x = i -> y
	  | _ :: _ :: xs -> assoc i xs
	  | [] -> ignore (sprintf "key %s not found" i)
	  | [_] -> ignore "odd number of elements in association list"
	in

	(* NB. We expect the rows to begin with a "connect" operation,
	 * then have a series of prepare/executes, and possibly finish
	 * with a "close".
	 *)
	let params, prog =
	  match rows with
	  | ("1" :: "connect" :: time :: status :: details) :: _ ->
	      { user = assoc "user" details;
		database = assoc "database" details;
		host = assoc "host" details;
		port = int_of_string (assoc "port" details) },
	      assoc "prog" details
	  | _ ->
	      ignore (sprintf "connection %s did not start with a 'connect' operation" uuid) in

	set_connection params
	  (fun data ->
	     { data with
		 progs = prog :: List.filter ((<>) prog) data.progs });

	(* qnames maps prepared query names to query. *)
	let qnames = Hashtbl.create 13 in

	List.iter (
	  function
	  | "1" :: "connect" :: time :: status :: details ->
	      let time = int_of_string time in
	      let failures = if status = "ok" then 0 else 1 in
	      set_connection params
		(fun data ->
		   { data with
		       nr_connects = data.nr_connects + 1;
		       connect_time = data.connect_time + time;
		       nr_failures = data.nr_failures + failures;
		   })

	  | "1" :: "prepare" :: time :: status :: details ->
	      let time = int_of_string time in
	      let failures = if status = "ok" then 0 else 1 in
	      let query = assoc "query" details in
	      let name = assoc "name" details in
	      (* Put it in qnames so we can look it up in execute below. *)
	      Hashtbl.replace qnames name query;

	      set_query query
		(fun data ->
		   { data with
		       qprogs = prog :: List.filter ((<>) prog) data.qprogs;
		       nr_preps = data.nr_preps + 1;
		       prep_time = data.prep_time + time;
		       nr_qfailures = data.nr_qfailures + failures;
		   })

	  | "1" :: "execute" :: time :: status :: details ->
	      let time = int_of_string time in
	      let failures = if status = "ok" then 0 else 1 in
	      let name = assoc "name" details in
	      let query =
		try Hashtbl.find qnames name
		with
		  Not_found -> ignore (sprintf "execute on unprepared query name '%s'" name) in
	      set_query query
		(fun data ->
		   { data with
		       nr_execs = data.nr_execs + 1;
		       exec_time = data.exec_time + time;
		       nr_qfailures = data.nr_qfailures + failures;
		   })

	  | "1" :: "close" :: time :: status :: _ ->
	      let time = int_of_string time in
	      let failures = if status = "ok" then 0 else 1 in
	      set_connection params
		(fun data ->
		   { data with
		       nr_closes = data.nr_closes + 1;
		       close_time = data.close_time + time;
		       nr_failures = data.nr_failures + failures;
		   })

	  | "1" :: "ping" :: time :: status :: _ ->
	      let time = int_of_string time in
	      let failures = if status = "ok" then 0 else 1 in
	      set_connection params
		(fun data ->
		   { data with
		       nr_pings = data.nr_pings + 1;
		       ping_time = data.ping_time + time;
		       nr_failures = data.nr_failures + failures;
		   })

	  | _ ->
	      ignore "invalid row"
	) rows
      with
	Ignore msg ->
	  eprintf "warning: %s\n" msg
  ) files

(* Clean up temporary directory. *)
let () =
  List.iter (
    fun filename ->
      Unix.unlink (tmpdir // filename)
  ) files;
  Unix.rmdir tmpdir

(* Sanity check - did we read back the same number of rows that
 * we wrote?
 *)
let () = assert (!nr_rows = !nr_rows')

(* More manageable as lists. *)
let queries =
  Hashtbl.fold (fun query data xs -> (query, data) :: xs) queries []
let connections =
  Hashtbl.fold (fun params data xs -> (params, data) :: xs) connections []

(* Sort them so that the ones with the most cumulative time are first. *)
let queries =
  let f
      (_, { prep_time = prep_time1; exec_time = exec_time1 })
      (_, { prep_time = prep_time2; exec_time = exec_time2 }) =
    compare (prep_time2 + exec_time2) (prep_time1 + exec_time1)
  in
  List.sort f queries
let connections =
  let f
      (_, { connect_time = connect_time1; close_time = close_time1;
	    ping_time = ping_time1 })
      (_, { connect_time = connect_time2; close_time = close_time2;
	    ping_time = ping_time2 }) =
    compare
      (connect_time2 + close_time2 + ping_time2)
      (connect_time1 + close_time1 + ping_time1)
  in
  List.sort f connections

(* Print out the results of the analysis. *)
let () =
  printf "---------------------------------------- QUERIES ---------\n\n";
  List.iter (
    fun (query, data) ->
      printf "Query:\n%s\n\n" query;
      printf "Total time: %d ms\n"
	(data.prep_time + data.exec_time);
      printf "   Prepare: %d ms\n" data.prep_time;
      printf "               Calls: %d\n" data.nr_preps;
      if data.nr_preps > 0 then
	printf "       Avg time/prep: %d ms\n"
	  (data.prep_time / data.nr_preps);
      printf "   Execute: %d ms\n" data.exec_time;
      printf "               Calls: %d\n" data.nr_execs;
      if data.nr_execs > 0 then
	printf "       Avg time/exec: %d ms\n"
	  (data.exec_time / data.nr_execs);
      printf "  Failures: %d\n" data.nr_qfailures;
      printf "Called from: %s\n"
	(String.concat ", " data.qprogs);

      printf "\n\n";
  ) queries;

  printf "---------------------------------------- CONNECTIONS -----\n\n";
  List.iter (
    fun (params, data) ->
      printf "Connection:\n";
      printf "      user = %s\n" params.user;
      printf "  database = %s\n" params.database;
      printf "      host = %s\n" params.host;
      printf "      port = %d\n" params.port;
      printf "\n";
      printf "Total time: %d ms\n"
	(data.connect_time + data.close_time + data.ping_time);
      printf "   Connect: %d ms\n" data.connect_time;
      printf "               Calls: %d\n" data.nr_connects;
      if data.nr_connects > 0 then
	printf "       Avg time/conn: %d ms\n"
	  (data.connect_time / data.nr_connects);
      printf "     Close: %d ms\n" data.close_time;
      printf "               Calls: %d\n" data.nr_closes;
      if data.nr_closes > 0 then
	printf "      Avg time/close: %d ms\n"
	  (data.close_time / data.nr_closes);
      printf "      Ping: %d ms\n" data.ping_time;
      printf "               Calls: %d\n" data.nr_pings;
      if data.nr_pings > 0 then
	printf "       Avg time/ping: %d ms\n"
	  (data.ping_time / data.nr_pings);
      printf "Called from: %s\n"
	(String.concat ", " data.progs);

      printf "\n\n";
  ) connections
