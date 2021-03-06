open Core
open Query_Types
open Query_Util
open Query_Table

module IntSetSet = Set.Make(Int.Set)
module IntSetMap = Map.Make(Int.Set)

let binary_of_str (s:string) : int =
   let n = String.length s in
   let rec add i =
      if i = n then 0
      else
      ((Caml.Char.code (s.[i])) lsl ((n-i-1)*8)) lor (add (i+1))
   in
   add 0

let make_mcast_group (al:QueryAction.t list) : Int.Set.t =
  List.fold_left
    ~init:Int.Set.empty
    ~f:(fun grp a ->
        match a with
        | QueryAction.ForwardPort (p) ->
            Int.Set.add grp p
        | _ -> raise (Failure "Cannot merge a fwd action with other types of actions"))
    al

let list_last (l:'a list) : 'a =
    List.nth_exn l ((List.length l) - 1)

let all_fwd_actions (al:QueryAction.t list) : bool =
  let is_fwd_act = function QueryAction.ForwardPort _ -> true | _ -> false in
  List.length al > 0 &&
  List.for_all ~f:is_fwd_act al

let get_mgid (mgid_for_group:int IntSetMap.t) (al:QueryAction.t list) =
  let grp = make_mcast_group al in
  IntSetMap.find_exn mgid_for_group grp

let global_priority = ref 9999

let get_priority () =
  global_priority := !global_priority - 1;
  !global_priority

module P4Table = struct
  type width = int [@@deriving compare, sexp]

  type value =
    | Number of int
    | IP of int
    | IPv6 of int * int * int * int
    | String of string
    [@@deriving compare, sexp]

  type action_name = string [@@deriving compare, sexp]

  type action =
    action_name * value list
    [@@deriving compare, sexp]

  type field_match =
    | EqMatch of value * width
    | LtMatch of value * width
    | GtMatch of value * width
    | RangeMatch of value * value * width
    | LpmMatch of value * value * width
    [@@deriving compare, sexp]

  type entry =
    field_match list * action
    [@@deriving compare, sexp]

  type t = {
    name: string;
    fields: QueryField.t list;
    entries: entry list;
    }
    [@@deriving compare, sexp]

  let field_to_table_name field =
    match field with
    | QueryField.HeaderField(h, f, _, _) ->
        Printf.sprintf "query_%s_%s" h f

  let get_field_width field =
    match field with
    | QueryField.HeaderField(_, _, _, w) -> w

  let _translate_value v =
    match v with
    | (QueryConst.Number i) | (QueryConst.MAC i) ->
        Number i
    | (QueryConst.IP i) -> IP i
    | QueryConst.IPv6 (a, b, c, d) -> IPv6 (a, b, c, d)
    | QueryConst.String s -> String s

  let _translate_match w m =
    match m with
    | QueryTable.EqMatch(v) -> [EqMatch(_translate_value v, w)]
    | QueryTable.LtMatch(v) -> [LtMatch(_translate_value v, w)]
    | QueryTable.GtMatch(v) -> [GtMatch(_translate_value v, w)]
    | QueryTable.RangeMatch(a, b) ->
        [RangeMatch(_translate_value a, _translate_value b, w)]
    | QueryTable.LpmMatch(a, b) ->
        [LpmMatch(_translate_value a, _translate_value b, w)]
    | QueryTable.Wildcard -> []

  let rec _to_num_list (l:int list) : value list =
    match l with
    | [] -> []
    | h::t -> (Number h)::(_to_num_list t)

  let _mk_term_action (qt:QueryTable.t) mgid_for_group al =
    let default_act = match qt.default_action with
      | None -> "query_drop"
      | Some a -> a
    in
    match al with
    | QueryAction.ForwardPort(p)::[] -> ("set_egress_port", [Number p])
    | QueryAction.P4Action(name, args)::[] -> (name, _to_num_list args)
    | _ when all_fwd_actions al ->  ("set_mgid", [Number (get_mgid mgid_for_group al)])
    (* no actions, drop *)
    | [] -> (default_act, [])
    | _ -> raise (Failure "Unable to generate table commands for this action or combination of actions")

  let _translate_terminal (qt:QueryTable.t) mgid_for_group e =
    match e with
    | QueryTable.Terminal(s, al) ->
        ([EqMatch(Number s, 16)], _mk_term_action qt mgid_for_group al)
    | _ -> raise (Failure "This is not a transition table")

  let _translate_transition w e =
    match e with
    | QueryTable.Transition(s1, m, s2) ->
        ([EqMatch(Number s1, 16)] @ (_translate_match w m),
          ("set_next_state", [Number s2]))
    | _ -> raise (Failure "This is not a transition table")

  let _make_terminal_tables (qt:QueryTable.t) (mgid_for_group:int IntSetMap.t) =
    let entries =
      List.map
        qt.entries
        ~f:(_translate_terminal qt mgid_for_group)
    in
    let state_field = QueryField.HeaderField("query", "state", 1, 16) in
    [{
          name = "query_actions";
          fields = [state_field];
          entries = entries;
    }]

  let _make_transition_tables (qt:QueryTable.t) : t list =
    let field =
      match qt.field with
      | Some f -> f
      | None -> raise (Failure "This table must be associated with a field")
    in
    let w = get_field_width field in
    let all_entries =
      List.map
        qt.entries
        ~f:(_translate_transition w)
    in
    let ex_entries, ra_entries, lpm_entries, mi_entries =
      List.fold_left
      ~init:([], [], [], []) (* exact, range, lpm, miss *)
      ~f:(fun (ex, ra, lpm, mi) e ->
          match e with
          | (_::(EqMatch _)::_, _) ->
              (e::ex, ra, lpm, mi)
          | (_::((LtMatch _)|(GtMatch _)|(RangeMatch _))::_, _) ->
              (ex, e::ra, lpm, mi)
          | (_::(LpmMatch _)::_, _) ->
              (ex, ra, e::lpm, mi)
          | (_::[], _) ->
              (ex, ra, lpm, e::mi)
          | _ -> raise (Failure "Bad entries"))
      all_entries
    in
    let state_field = QueryField.HeaderField("query", "state", 1, 16) in
    let ex_table =
      if List.length ex_entries = 0 then
        []
      else
        [{
          name = (field_to_table_name field) ^ "_exact";
          fields = [state_field; field];
          entries = ex_entries;
        }]
    in
    let ra_table =
      if List.length ra_entries = 0 then
        []
      else
        [{
          name = (field_to_table_name field) ^ "_range";
          fields = [state_field; field];
          entries = ra_entries;
        }]
    in
    let lpm_table =
      if List.length lpm_entries = 0 then
        []
      else
        [{
          name = (field_to_table_name field) ^ "_lpm";
          fields = [state_field; field];
          entries = lpm_entries;
        }]
    in
    let mi_table =
      if List.length mi_entries = 0 then
        []
      else
        [{
          name = (field_to_table_name field) ^ "_miss";
          fields = [state_field];
          entries = mi_entries;
        }]
    in
    ex_table @ ra_table @ lpm_table @ mi_table

  let from_abstract (qt:QueryTable.t) (mgid_for_group:int IntSetMap.t) : t list =
    if qt.is_terminal then
      _make_terminal_tables qt mgid_for_group
    else
      _make_transition_tables qt

  let is_ternary matches =
    List.exists
      matches
      ~f:(fun m ->
          match m with
          | (RangeMatch _) | (LtMatch _) | (GtMatch _) -> true
          | _ -> false)

  let space_pad_str s n : string =
    s ^ (String.make (max 0 (n - (String.length s))) ' ')

  let str_of_value v w inc =
    match v with
    | Number i -> Printf.sprintf "%u" (i + inc)
    | IP i -> Printf.sprintf "%u" (i + inc)
    | IPv6 (a, b, c, d) ->
        let open Stdint.Uint128 in
        to_string
        (logor (shift_left (of_int a) 96)
        (logor (shift_left (of_int b) 64)
        (logor (shift_left (of_int c) 32)
                           (of_int d))))
    | String s -> Printf.sprintf "%u" (binary_of_str (space_pad_str s (w/8)))

  let format_value v =
    match v with
    | IP i ->
        Printf.sprintf "%d.%d.%d.%d"
          ((i lsr 24) land 255)
          ((i lsr 16) land 255)
          ((i lsr 8)  land 255)
          (i land 255)
    | _ -> Printf.sprintf "%s" (str_of_value v 0 0)

  let format_args args =
    Caml.String.concat " "
      (List.map
        args
        ~f:format_value)

  let format_match m =
    match m with
    | EqMatch(v, _) ->
        format_value v
    | LtMatch (v, w) ->
        Printf.sprintf "0x00->%s" (str_of_value v w (-1))
    | GtMatch (v, w) ->
        Printf.sprintf "%s->0x%x" (str_of_value v w 1) ((int_exp 2 w)-1)
    | RangeMatch(a, b, w) when (str_of_value a w 0) < (str_of_value b w 0) ->
        Printf.sprintf "%s->%s" (str_of_value a w 0) (str_of_value b w 0)
    | RangeMatch(a, b, w) ->
        Printf.sprintf "%s->%s" (str_of_value b w 0) (str_of_value a w 0)
    | LpmMatch(a, b, w) ->
        Printf.sprintf "%s/%s" (format_value a) (str_of_value b w 0)

  let json_format_match m =
    match m with
    | EqMatch(v, w) ->
        Printf.sprintf "[%s]" (str_of_value v w 0)
    | LtMatch (v, w) ->
        Printf.sprintf "[0, %s]" (str_of_value v w (-1))
    | GtMatch (v, w) ->
        Printf.sprintf "[%s, %d]" (str_of_value v w 1) ((int_exp 2 w)-1)
    | RangeMatch(a, b, w) when (str_of_value a w 0) < (str_of_value b w 0) ->
        Printf.sprintf "[%s, %s]" (str_of_value a w 0) (str_of_value b w 0)
    | RangeMatch(a, b, w) ->
        Printf.sprintf "[%s, %s]" (str_of_value b w 0) (str_of_value a w 0)
    | LpmMatch(a, b, w) ->
        Printf.sprintf "[%s, %s]" (str_of_value a w 0) (str_of_value b w 0)

  let format_matches ms =
    Caml.String.concat " "
      (List.map
        ms
        ~f:format_match)

  let format_entry table_name e =
    let (matches, (act, args)) = e in
    let priority = if is_ternary matches then
      Printf.sprintf "%d" (get_priority ()) else "" in
    Printf.sprintf
      "table_add %s %s %s => %s %s"
      table_name act (format_matches matches) (format_args args) priority


  let format_t oc t =
    List.iter
      (List.map t.entries ~f:(format_entry t.name))
      ~f:(Printf.fprintf oc "%s\n")


  let json (oc:Out_channel.t) t =
    let json_matches ms : string =
      Caml.String.concat ","
        (List.map2_exn t.fields ms ~f:(fun hf m ->
          let h,f = match hf with QueryField.HeaderField(h, f, _, _) -> h, f in
          let hdr = if h = "query" && f = "state" then "meta" else "hdr" in
          Printf.sprintf "\"%s.%s.%s\": %s" hdr h f (json_format_match m))) in
    let arg_name act =
      match act with
      | "set_next_state" -> "next_state"
      | "set_mgid" -> "mgid"
      | "set_egress_port" -> "port"
      | _ ->  "arg1"
    in
    let json_entry e =
      let (matches, (act, args)) = e in
      let priority = if is_ternary matches then
        Printf.sprintf ", \"priority\": %d" (get_priority ()) else "" in
      let params =
        if (List.length args) > 0 then
          (Printf.sprintf ", \"action_params\": {\"%s\": %s}" (arg_name act)
          (str_of_value  (List.hd_exn args) 0 0)
          ) else "" in
      Printf.sprintf "{\"table_name\": \"Camus.%s\", \"match_fields\": {%s}, \"action_name\": \"Camus.%s\"%s%s}"
        t.name (json_matches matches) act params priority
      in
    List.iter
      (List.map t.entries ~f:json_entry)
      ~f:(fun e -> Printf.fprintf oc "%s,\n" e)

end

module P4RuntimeConf = struct

  type mcast_group = Int.Set.t
    [@@deriving compare, sexp]

  type t = {
    tables: P4Table.t String.Map.t;
    mcast_groups: mcast_group Int.Map.t;
    }
    [@@deriving compare, sexp]


  let from_abstract (qtp:QueryTablePipeline.t) =
    let actions_table = list_last qtp.tables in
    let mcast_groups : IntSetSet.t =
      List.fold_left
        ~init:IntSetSet.empty
        ~f:(fun grps e ->
            match e with
            | Terminal (_, al) ->
                if all_fwd_actions al then
                  (IntSetSet.add grps (make_mcast_group al))
                else
                  grps
            | Transition _ -> raise (Failure "Actions table should only contain Terminals"))
          actions_table.entries
    in
    let group_for_mgid : IntSetSet.Elt.t Int.Map.t = (* assign the mgids *)
      fst (IntSetSet.fold
        ~init:(Int.Map.empty, 0)
        ~f:(fun (grps, last_mgid) grp ->
          let mgid = last_mgid + 1 in
          (Int.Map.add grps ~key:mgid ~data:grp, mgid))
        mcast_groups)
    in
    let mgid_for_group : int IntSetMap.t =
      Int.Map.fold
        group_for_mgid
        ~init:IntSetMap.empty
        ~f:(fun ~key:mgid ~data:port_set m ->
          IntSetMap.add m ~key:port_set ~data:mgid)
    in
    let add_to_map (m:P4Table.t String.Map.t) (tbls:P4Table.t list) : P4Table.t String.Map.t =
      List.fold_left
        ~init:m
        ~f:(fun tbl_map tbl ->
          String.Map.add tbl_map ~key:tbl.name ~data:tbl)
        tbls
    in
    let tables : P4Table.t String.Map.t =
      List.fold_left
        ~init:String.Map.empty
        ~f:(fun m qtbl ->
          add_to_map m (P4Table.from_abstract qtbl mgid_for_group))
        qtp.tables
    in
    {
      tables = tables;
      mcast_groups = group_for_mgid;
    }


  let format_commands oc t =
      List.iter (String.Map.data t.tables) ~f:(P4Table.format_t oc)

  let dump_json oc t =
    Printf.fprintf oc "[";
    List.iter
      (String.Map.data t.tables)
      ~f:(P4Table.json oc);
    Printf.fprintf oc "\nnull]"

  let format_mcast_groups t =
    Caml.String.concat "\n"
      (Int.Map.fold
        ~init:[]
        ~f:(fun ~key:mgid ~data:port_set l ->
          let ports = Int.Set.to_list port_set in
          let line =
            Printf.sprintf "%d: %s"
              mgid
              (format_list ~sep:" " string_of_int ports) in
          l @ [line])
        t.mcast_groups)

end

