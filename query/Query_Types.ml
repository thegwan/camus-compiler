open Core
open Query_Formula
open Query_Util

(* Parser and surface language types *)
type info = string * (int * int) * (int * int)

type query_annotation =
  | QueryControl
  | QueryField of string * string * int
  | QueryFieldExact of string * string * int
  | QueryFieldRange of string * string * int
  | QueryFieldLpm of string * string * int
  | QueryFieldCounter of string * int
  | QueryDefaultAction of string


module QueryConst = struct
  type t =
    | Number of int
    | IP of int
    | IPv6 of int * int * int * int
    | MAC of int
    | String of string
    [@@deriving compare, sexp]

  let format_t t =
    match t with
    | String s -> s
    | Number(n) ->
        string_of_int n
    | IP(i) ->
        Printf.sprintf "%d.%d.%d.%d"
          ((i lsr 24) land 255)
          ((i lsr 16) land 255)
          ((i lsr 8)  land 255)
          (i land 255)
    | IPv6(a, b, c, d) ->
        Printf.sprintf "%x:%x:%x:%x:%x:%x:%x:%x"
          (a lsr 16) (a land 0xffff)
          (b lsr 16) (b land 0xffff)
          (c lsr 16) (c land 0xffff)
          (d lsr 16) (d land 0xffff)
    | MAC(i) ->
        Printf.sprintf "%d:%d:%d:%d:%d:%d"
          ((i lsr 40) land 255)
          ((i lsr 32) land 255)
          ((i lsr 24) land 255)
          ((i lsr 16) land 255)
          ((i lsr 8)  land 255)
          (i land 255)

  let rec compare_ipv6 l1 l2 =
    match (l1, l2) with
    | h1::t1, h2::t2 ->
        let c = Pervasives.compare h1 h2 in
        if c = 0 then compare_ipv6 t1 t2 else c
    | [], [] -> 0
    | _ -> raise (Failure "Addresses must have same size")

  let compare a b =
    match (a, b) with
    | (IPv6 (a1, a2, a3, a4), IPv6 (b1, b2, b3, b4)) ->
        compare_ipv6 [a1; a2; a3; a4] [b1; b2; b3; b4]
    | (_, IPv6 _) -> 1
    | (IPv6 _, _) -> -1
    | (((Number x)|(IP x)|(MAC x)), ((Number y)|(IP y)|(MAC y))) ->
        Pervasives.compare x y
    | (((Number _)|(IP _)|(MAC _)), String s) -> 1
    | (String s, ((Number _)|(IP _)|(MAC _))) -> -1
    | (String s1, String s2) ->
        Pervasives.compare s1 s2

  let min (a:t) (b:t) : t =
    if compare a b < 0 then a else b

  let max (a:t) (b:t) : t =
    if compare a b > 0 then b else a

  let to_int (a:t) : int =
    match a with
    | Number i -> i
    | _ -> raise (Failure "Cannot convert this QueryConst to int")
end


module QueryField = struct
  type priority = int [@@deriving compare, sexp]
  type width = int [@@deriving compare, sexp]

  type t =
    | HeaderField of string * string * priority * width
    [@@deriving compare, sexp]

  let format_t t =
    match t with
    | HeaderField(h, f, _, _) -> Printf.sprintf "%s.%s" h f

  let compare a b =
    let apr =
      match a with
      | HeaderField(_, _, pr, _) -> pr in
    let bpr =
      match b with
      | HeaderField(_, _, pr, _) -> pr in
    Int.compare apr bpr

end

module AssignmentMap = Map.Make(QueryField)

module AtomicPredicate = struct
  type t =
    | Eq of QueryField.t * QueryConst.t
    | Lt of QueryField.t * QueryConst.t
    | Gt of QueryField.t * QueryConst.t
    | Lpm of QueryField.t * QueryConst.t * QueryConst.t
    [@@deriving compare, sexp]

  type assignments = QueryConst.t AssignmentMap.t

  let compare a b =
    match (a, b) with
    | (Eq(x, String s1), Eq(y, String s2)) when x=y -> String.compare s1 s2
    | (Gt(x, Number n1), Gt(y, Number n2)) when x=y -> Int.compare n2 n1
    | (Lt(x, Number n1), Lt(y, Number n2)) when x=y -> Int.compare n1 n2
    | (Eq(x, Number n1), Eq(y, Number n2)) when x=y -> Int.compare n1 n2
    | (Eq(x, IP a1), Eq(y, IP a2)) when x=y -> Int.compare a1 a2
    | (Lpm(x, IP a1, Number m1), Lpm(y, IP a2, Number m2)) when x=y ->
        if a1=a2 then Int.compare m1 m2 else Int.compare a1 a2
    | (Eq(x, ((IPv6 _) as a1)), Eq(y, ((IPv6 _) as a2))) when x=y ->
        QueryConst.compare a1 a2
    | (Lpm(x, ((IPv6 _) as a1), Number m1), Lpm(y, ((IPv6 _) as a2), Number m2)) when x=y ->
        if a1=a2 then Int.compare m1 m2 else QueryConst.compare a1 a2
    (* Eq < Lpm *)
    | (Eq(x, _), Lpm(y, _, _)) when x=y -> -1
    | (Lpm(x, _, _), Eq(y, _)) when x=y -> 1
    (* Lt < Gt < Eq *)
    | (Eq(x, _), Lt(y, _)) when x=y -> 1
    | (Eq(x, _), Lt(y, _)) when x=y -> 1
    | (Eq(x, _), Gt(y, _)) when x=y -> 1
    | (Lt(x, _), Eq(y, _)) when x=y -> -1
    | (Lt(x, _), Gt(y, _)) when x=y -> -1
    | (Gt(x, _), Eq(y, _)) when x=y -> -1
    | (Gt(x, _), Lt(y, _)) when x=y -> 1
    (* Eq < Lt < Gt *)
    (*
    | (Eq(x, _), Lt(y, _)) when x=y -> -1
    | (Eq(x, _), Gt(y, _)) when x=y -> -1
    | (Lt(x, _), Eq(y, _)) when x=y -> 1
    | (Lt(x, _), Gt(y, _)) when x=y -> -1
    | (Gt(x, _), Eq(y, _)) when x=y -> 1
    | (Gt(x, _), Lt(y, _)) when x=y -> 1
    *)
    | ((Eq(x, _) | Lt(x, _) | Gt(x, _) | Lpm(x, _, _)), (Eq(y, _) | Lt(y, _) | Gt(y, _) | Lpm(y, _, _))) ->
        QueryField.compare x y

  let format_t t =
    match t with
    | Lt(qf, c) -> Printf.sprintf "%s<%s" (QueryField.format_t qf) (QueryConst.format_t c)
    | Gt(qf, c) -> Printf.sprintf "%s>%s" (QueryField.format_t qf) (QueryConst.format_t c)
    | Eq(qf, c) -> Printf.sprintf "%s=%s" (QueryField.format_t qf) (QueryConst.format_t c)
    | Lpm(qf, c1, c2) -> Printf.sprintf "%s=%s/%s" (QueryField.format_t qf) (QueryConst.format_t c1) (QueryConst.format_t c2)

  let disjoint t1 t2 =
    match (t1, t2) with
    | (Eq(a, x), Eq(b, y)) when a=b -> x<>y
    | (Gt(a, Number x), Eq(b, Number y)) when a=b -> y<=x
    | (Eq(b, Number y), Gt(a, Number x)) when a=b -> y<=x
    | (Lt(a, Number x), Eq(b, Number y)) when a=b -> y>=x
    | (Eq(b, Number y), Lt(a, Number x)) when a=b -> y>=x
    | (Lt(a, Number x), Gt(b, Number y)) when a=b -> x<=(y+1)
    | (Gt(b, Number y), Lt(a, Number x)) when a=b -> x<=(y+1)
    | (Lpm(a, IP a1, Number m1), Lpm(b, IP a2, Number m2)) when a=b -> a1<>a2
    | (Lpm(a, ((IPv6 _) as a1), Number m1), Lpm(b, ((IPv6 _) as a2), Number m2)) when a=b -> a1<>a2
    | _ -> false

  let subset sub sup =
    match (sub, sup) with
    (* TODO: check for subset IP prefixes *)
    | (Gt(a, Number x), Gt(b, Number y)) when a=b -> x>=y
    | (Lt(a, Number x), Lt(b, Number y)) when a=b -> x<=y
    | (Eq(a, Number x), Gt(b, Number y)) when a=b -> x>y
    | (Eq(a, Number x), Lt(b, Number y)) when a=b -> x<y
    | _ -> false

  let field t =
    match t with
    | Lt(qf, _) | Gt(qf, _) | Eq(qf, _) | Lpm(qf, _, _) -> qf

  let independent t1 t2 =
    field t1 <> field t2

  let equal a b =
    compare a b = 0

  let hash x =
    Hashtbl.hash x

  let eval (a:assignments) (p:t) =
    let f = field p in
    let v = AssignmentMap.find_exn a f in
    match p, v with
    | Eq(_, Number x), Number y -> y = x
    | Gt(_, Number x), Number y -> y > x
    | Lt(_, Number x), Number y -> y < x
    | Eq(_, String x), String y -> y = x
    | _ -> raise (Failure "Invalid assignment")

  module ConstRange = struct
    type t =
      QueryConst.t option * QueryConst.t option
      [@@deriving compare, sexp]

    let set_lt cr x : t =
      match cr with
      | (a, _) -> (a, Some (QueryConst.Number ((QueryConst.to_int x)-1)))

    let set_gt cr x : t =
      match cr with
      | (_, b) -> (Some (QueryConst.Number ((QueryConst.to_int x)+1)), b)

    let set_eq cr x : t =
      match cr with
      | _ -> (Some x, Some x)

    let implies_true_eq cr x : bool = match cr with
      | (Some a, Some b) -> a = x && b = x
      | _ -> false

    let implies_true_lt cr x : bool = match cr with
      | (_, Some b) -> (QueryConst.compare b x) < 0
      | _ -> false

    let implies_true_gt cr x : bool = match cr with
      | (Some a, _) -> (QueryConst.compare a x) > 0
      | _ -> false

  end

  type var_type = t
    [@@deriving compare, sexp]

  module DummyConstraintSet = struct
    type t = int
      [@@deriving compare, sexp]
    let empty = 0
    let add_constraint cs var = cs
    let implies_true cs var = false
    let implies_false cs var = raise (Failure "Unimplemented")
  end

  module PredicateConstraintSet = struct
    module FieldMap = Map.Make(QueryField)
    type t = ConstRange.t FieldMap.t
      [@@deriving compare, sexp]
    let empty = FieldMap.empty

    let getcr cs qf =
      match FieldMap.find cs qf with
      | None -> (None, None)
      | Some x -> x

    let add_constraint cs var =
      let qf = field var in
      let cr = getcr cs qf in
      let cr2 =
        match var with
        | Eq (_, x) -> ConstRange.set_eq cr x
        | Lt (_, x) -> ConstRange.set_lt cr x
        | Gt (_, x) -> ConstRange.set_gt cr x
        | Lpm _ -> cr (* TODO: add a Lpm to a constraint set *)
      in
      FieldMap.add cs ~key:qf ~data:cr2

    let implies_true cs var =
      let cr = getcr cs (field var) in
      match var with
      | Eq (_, x) -> ConstRange.implies_true_eq cr x
      | Lt (_, x) -> ConstRange.implies_true_lt cr x
      | Gt (_, x) -> ConstRange.implies_true_gt cr x
      | Lpm _ -> false (* TODO we should check this *)

    let implies_false cs var =
      raise (Failure "Unimplemented")
  end

  module ConstraintSet = DummyConstraintSet

end

module QueryFormula = Formula(AtomicPredicate)

let format_int_list l =
  String.concat ~sep:"," (List.map ~f:string_of_int l)

module QueryAction = struct
  type t =
    | ForwardPort of int
    | P4Action of string * int list
    [@@deriving compare, sexp]

  let format_t t =
    match t with
    | ForwardPort(p) -> string_of_int p
    | P4Action(name, args) -> Printf.sprintf "%s(%s)" name (format_int_list args)

  let compare a b =
    match a, b with
    | ForwardPort p1, ForwardPort p2 ->
        Pervasives.compare p1 p2
    | _ -> raise (Failure "Cannot compare actions of different types")

  let hash t =
    match t with
    | ForwardPort p ->
        Hashtbl.hash p
    | P4Action (act, l) ->
        (Hashtbl.hash act) + (List.fold_left ~init:0 ~f:(+) (List.map ~f:Hashtbl.hash l))

end

module QueryRule = struct
  type t =
    QueryFormula.t * QueryAction.t list
    [@@deriving compare, sexp]

  let format_t (q, acts) =
    Printf.sprintf "%s: %s;" (QueryFormula.format_t q) (format_list QueryAction.format_t acts)

  let from_ast (rl:Query_Ast.rule_list) : t list =
    let const_of_exp e =
      let open QueryConst in
      match e with
      | Query_Ast.NumberLit i -> Number i
      | Query_Ast.IpAddr i -> IP i
      | Query_Ast.MacAddr i -> MAC i
      | Query_Ast.StringLit s -> String s
      | Query_Ast.Ip6Addr (a, b, c, d) -> IPv6 (a, b, c, d)
      | _ -> raise (Failure "Should be a const value")
    in
    let str_of_exp e =
      let open QueryConst in
      match e with
      | Query_Ast.Field (_, f) -> f
      | _ -> raise (Failure "Should be a const string value")
    in

    let rec form_of_exp e =
      let open QueryFormula in
      let open AtomicPredicate in
      match e with
      | Query_Ast.Not(x) -> Not(form_of_exp x)
      | Query_Ast.And(x, y) -> And(form_of_exp x, form_of_exp y)
      | Query_Ast.Or(x, y) -> Or(form_of_exp x, form_of_exp y)
      | Query_Ast.Eq(Query_Ast.Field(h, f), y) ->
          let hf = QueryField.HeaderField(h, f, 0, 0) in
          Atom(AtomicPredicate.Eq(hf, const_of_exp y))
      | Query_Ast.Eq(Query_Ast.Call(func, f::_), y) ->
          assert (func <> "inc");
          let hf = QueryField.HeaderField("stful_meta", str_of_exp f, 0, 0) in
          Atom(AtomicPredicate.Eq(hf, const_of_exp y))
      | Query_Ast.Eq _ -> raise (Failure "Bad format for Eq")
      | Query_Ast.Lt(Query_Ast.Field(h, f), y) ->
          let hf = QueryField.HeaderField(h, f, 0, 0) in
          Atom(AtomicPredicate.Lt(hf, const_of_exp y))
      | Query_Ast.Lt(Query_Ast.Call(func, f::_), y) ->
          let hf = QueryField.HeaderField("stful_meta", str_of_exp f, 0, 0) in
          Atom(AtomicPredicate.Lt(hf, const_of_exp y))
      | Query_Ast.Lt _ -> raise (Failure "Bad format for Lt")
      | Query_Ast.Gt(Query_Ast.Field(h, f), y) ->
          let hf = QueryField.HeaderField(h, f, 0, 0) in
          Atom(AtomicPredicate.Gt(hf, const_of_exp y))
      | Query_Ast.Gt(Query_Ast.Call(func, f::_), y) ->
          let hf = QueryField.HeaderField("stful_meta", str_of_exp f, 0, 0) in
          Atom(AtomicPredicate.Gt(hf, const_of_exp y))
      | Query_Ast.Lpm(Query_Ast.Field(h, f), addr, mask) ->
          let hf = QueryField.HeaderField(h, f, 0, 0) in
          Atom(AtomicPredicate.Lpm(hf, const_of_exp addr, const_of_exp mask))
      | Query_Ast.Lpm _ -> raise (Failure "Bad format for Lpm")
      | Query_Ast.Gt _ -> raise (Failure "Bad format for Gt")
      | Query_Ast.Call _ -> raise (Failure "Unsupported Call")
      | (Query_Ast.Field _) | (Query_Ast.StringLit _)
      | (Query_Ast.NumberLit _) | (Query_Ast.IpAddr _) | (Query_Ast.Ip6Addr _) |(Query_Ast.MacAddr _) ->
          raise (Failure "Unexpected value here")
    in

    let rec ints_of_lits (l:Query_Ast.expr list) : int list =
      match l with
      | [] -> []
      | Query_Ast.NumberLit(i)::t -> i::(ints_of_lits t)
      | Query_Ast.IpAddr(i)::t -> i::(ints_of_lits t)
      | _ -> raise (Failure "Must all be number literals")
    in

    let act_of_exp e =
      match e with
      | Query_Ast.Call("fwd", [Query_Ast.NumberLit(i)]) -> QueryAction.ForwardPort i
      | Query_Ast.Call("fwd", _) -> raise (Failure "Bad fwd action")
      | Query_Ast.Call(act, args) -> QueryAction.P4Action(act, (ints_of_lits args))
      | _ -> raise (Failure "Action must be of Call type, e.g. fwd(1)")
    in

    List.map
      rl
      ~f:(fun (q, al) ->
        (form_of_exp q,
        List.map ~f:act_of_exp al))
end
