open Core
open Query_Formula

type query_annotation =
  | QueryControl
  | QueryField of string * string * int
  | QueryFieldExact of string * string * int
  | QueryFieldRange of string * string * int
  | QueryFieldLpm of string * string * int
  | QueryFieldCounter of string * int
  | QueryDefaultAction of string

module QueryConst : sig
  type t =
    | Number of int
    | IP of int
    | IPv6 of int * int * int * int
    | MAC of int
    | String of string
    [@@deriving compare, sexp]

  val compare : t -> t -> int
  val min : t -> t -> t
  val max : t -> t -> t
  val to_int : t -> int
  val format_t : t -> string
end

module QueryField : sig
  type priority = int [@@deriving compare, sexp]
  type width = int [@@deriving compare, sexp]

  type t =
    | HeaderField of string * string * priority * width
    [@@deriving compare, sexp]

  val format_t : t -> string

  val compare : t -> t -> int
end

module AtomicPredicate : sig
  type t =
    | Eq of QueryField.t * QueryConst.t
    | Lt of QueryField.t * QueryConst.t
    | Gt of QueryField.t * QueryConst.t
    | Lpm of QueryField.t * QueryConst.t * QueryConst.t
    [@@deriving compare, sexp]

  type assignments

  val compare : t -> t -> int
  val equal : t -> t -> bool
  val hash : t -> int

  val format_t : t -> string
  val disjoint : t -> t -> bool
  val subset : t -> t -> bool
  val independent : t -> t -> bool
  val field : t -> QueryField.t
  val eval : assignments -> t -> bool

  module ConstRange : sig
    type t =
      QueryConst.t option * QueryConst.t option
      [@@deriving compare, sexp]
  end

  type var_type = t
    [@@deriving compare, sexp]

  module ConstraintSet : sig
    type t
      [@@deriving compare, sexp]
    val empty : t
    val add_constraint : t -> var_type -> t
    val implies_true : t -> var_type -> bool
    val implies_false : t -> var_type -> bool
  end
end

module QueryFormula : module type of Formula(AtomicPredicate)

module QueryAction : sig
  type t =
    | ForwardPort of int
    | P4Action of string * int list
    [@@deriving compare, sexp]

  val format_t : t -> string
  val compare : t -> t -> int
  val hash : t -> int
end

module QueryRule : sig
  type t =
    QueryFormula.t * QueryAction.t list
    [@@deriving compare, sexp]

  val format_t : t -> string
  val from_ast : Query_Ast.rule_list -> t list
end
