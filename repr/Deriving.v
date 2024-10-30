(** This file implements a Coq command that automatically derives [Repr] instances
    for inductives and records. *)

From Coq Require Import PrimString List.
From MetaCoq.Template Require Import All.
From MetaCoq.Utils Require Import monad_utils.
From PPrint Require Import All.
From Repr Require Import Class Utils LocallyNameless Class.

Import ListNotations MCMonadNotation.
Open Scope list_scope.

Set Universe Polymorphism.

(** Pretty-print the constructor argument [arg]. *)
Definition repr_arg {A} `{Repr A} (arg : A) : doc unit :=
  repr_doc (S app_precedence) arg.

(** Pretty-print the application of constructor [label] to a list of arguments [args]. *)
Definition repr_ctor (min_prec : nat) (label : pstring) (args : list (doc unit)) : doc unit :=
  (*let res := separate (break 1) (str label :: args) in*)
  let res := 
    match args with 
    | [] => str label
    | _ => paren_if min_prec app_precedence $ flow (break 1) (str label :: args) 
    end
  in
  group $ hang 2 res.

(** Quote some terms that we will need below. *)
MetaCoq Quote Definition quoted_repr_arg := (@repr_arg).
MetaCoq Quote Definition quoted_repr_ctor := (@repr_ctor).
MetaCoq Quote Definition quoted_doc_unit := (doc unit).
MetaCoq Quote Definition quoted_nil := (@nil).
MetaCoq Quote Definition quoted_cons := (@cons).
MetaCoq Quote Definition quoted_nat := (nat).
MetaCoq Quote Definition quoted_Repr := (Repr).
MetaCoq Quote Definition quoted_Build_Repr := (Build_Repr).

(** * Pure code. *)

(** For technical reasons related to fixpoints and nested inductives, building the [Repr] 
    instance the traditional way :
    [
      Instance repr_list A (Repr A) : Repr (list A) :=
      { 
        repr_doc := 
          fix f prec x : doc unit := ... 
      }
    ] 
    does not work in general.

    Instead, I build the instance in two steps. First build a _raw function_ with return type [doc unit] :
    [
      Fixpoint raw_func A (Repr A) (prec : nat) (x : list A) : doc unit := ...
    ]
    and then package it in an instance :
    [
      Instance repr_list A (RA : Repr A) : Repr (list A) :=
      { repr_doc := raw_func A RA }
    ] 
*)

(** In general the raw function takes many inputs : we package them in a record. *)
Record inputs :=
  { (** The parameters of the inductive, ordered from first to last. *)
    params : list ident 
  ; (** The indices of the inductive, ordered from first to last. *)
    indices : list ident 
  ; (** A [Repr] instance for each parameter. *)
    insts : list ident
  ; (** The precedence level (of type [nat]). *)
    prec : ident 
  ; (** The object to pretty-print (of type [ind params indices]). *)
    x : ident }.

(** [input_vars inp] is a helper function to get the list of all inputs to the raw function,
    in the same order the function is supposed to take them. *)
Definition input_vars (inp : inputs) : list ident :=
  List.concat [inp.(params); inp.(indices); inp.(insts); [inp.(prec); inp.(x)]]. 

(** Same as [input_inst_vars], but without [prec] and [x]. *)
Definition input_inst_vars (inp : inputs) : list ident :=
  List.concat [inp.(params); inp.(indices); inp.(insts)]. 

(** [apply_ind pi inp] is a helper function to apply the inductive [pi] to
    the parameters and indices in the inputs [inp]. *)
Definition apply_ind (pi : packed_inductive) (inp : inputs) : term :=
  mkApps (tInd pi.(pi_ind) []) $ List.map tVar $ inp.(params) ++ inp.(indices).

(** Helper function to add the raw function's inputs to the context. *)
Definition with_func_inputs {T} ctx (pi : packed_inductive) (k : NamedCtx.t -> inputs -> T) : T :=
  (* Declare the inductive parameters. *)
  with_ind_params ctx pi $ fun ctx params =>
  (* Declare the inductive indices. *)
  with_ind_indices ctx pi (List.map tVar params) $ fun ctx indices =>
  (* Declare a Repr instance for each parameter. *)
  let repr_decls := List.map (fun p => mk_decl "H"%bs $ mkApp quoted_Repr p) (List.map tVar params) in
  with_decls ctx repr_decls $ fun ctx insts =>
  (* Declare the minimum precedence [min_prec]. *)
  with_decl ctx (mk_decl "min_prec"%bs quoted_nat) $ fun ctx prec =>
  (* Declare the input parameter [x]. *)
  let I := mkApps (tInd pi.(pi_ind) []) $ List.map tVar $ params ++ indices in
  with_decl ctx (mk_decl "x"%bs I) $ fun ctx x =>  
  (* Call the continuation. *)
  k ctx (Build_inputs params indices insts prec x).
  
(** [term_list ty xs] builds the term corresponding to the list [x1; ...; xn], 
    assuming each [xi] has type [ty]. *)
Fixpoint term_list (ty : term) (xs : list term) : term :=
  match xs with 
  | [] => mkApp quoted_nil ty
  | x :: xs => mkApps quoted_cons [ty; x; term_list ty xs]
  end.
   
(** Build a single argument. *)
Definition build_arg ctx (arg : ident) : term :=
  (* I use an evar in place of the [Repr] instance, which will be solved when unquoting the term. *)
  mkApps quoted_repr_arg [NamedCtx.get_type ctx arg; fresh_evar ctx; tVar arg].

(** Build a branch for a single constructor. *)
Definition build_branch ctx (inp : inputs) (pc : packed_constructor) (quoted_ctor_name : term) : branch term :=
  (* Get the list of arguments of the constructor. *)
  with_ctor_args ctx pc (List.map tVar inp.(params)) $ fun ctx args =>
  (* Apply [repr_ctor] to the precedence, label and the arguments. *)
  let repr_args := term_list quoted_doc_unit $ List.map (build_arg ctx) args in
  mk_branch ctx args $ mkApps quoted_repr_ctor [tVar inp.(prec); quoted_ctor_name; repr_args].

(** Bind the recursive [Repr] instance using a let-in. *)
Definition with_rec_inst {T} ctx (pi : packed_inductive) (fix_param : term) (k : NamedCtx.t -> ident -> T) : T :=
  let body := 
    with_func_inputs ctx pi $ fun ctx inp =>
    let body := mkApps fix_param $ List.map tVar $ inp.(params) ++ inp.(indices) ++ inp.(insts) in
    mk_lambdas ctx (inp.(params) ++ inp.(indices) ++ inp.(insts)) $ 
      mkApps quoted_Build_Repr [apply_ind pi inp ; body]
  in 
  let decl := 
    {| decl_name := {| binder_name := nNamed "rec_inst"%bs ; binder_relevance := Relevant |}
    ;  decl_type := fresh_evar ctx
    ;  decl_body := Some body |}
  in
  with_decl ctx decl k.

(** Build the case expression. *)
Definition build_match ctx (pi : packed_inductive) (inp : inputs) (ctor_names : list term) : term :=
  (* Case info. *)  
  let ci := {| ci_ind := pi.(pi_ind) ; ci_npar := pi.(pi_mbody).(ind_npars) ; ci_relevance := Relevant |} in
  (* Case predicate. *)
  let pred := 
    let params := List.map tVar inp.(params) in
    with_ind_indices ctx pi params $ fun ctx indices =>
    with_decl ctx (mk_decl "x"%bs $ mkApps (tInd pi.(pi_ind) []) params) $ fun ctx x => 
      mk_pred ctx params indices x quoted_doc_unit
  in
  (* Case branches. *)
  let branches := map2 (build_branch ctx inp) (pi_ctors pi) ctor_names in
  (* Result. *)
  tCase ci pred (tVar inp.(x)) branches.

(** Build the raw function's type. *)
Definition build_func_ty ctx (pi : packed_inductive) : term :=
  with_func_inputs ctx pi $ fun ctx inp =>
    mk_prods ctx (input_vars inp) quoted_doc_unit.

(** Build the raw function (normal variant). *)
Definition build_func_normal ctx (pi : packed_inductive) (ctor_names : list term) : term :=
  with_func_inputs ctx pi $ fun ctx inp =>
  let body := build_match ctx pi inp ctor_names in
  mk_lambdas ctx (input_vars inp) body.

(** Build the raw function (fixpoint variant). *)
Definition build_func_fix ctx (pi : packed_inductive) (ctor_names : list term) : term :=
  (* Declare the fixpoint parameter. *)
  with_decl ctx (mk_decl "fix_param"%bs $ build_func_ty ctx pi) $ fun ctx fix_param =>
  (* Declare the function inputs. *)
  with_func_inputs ctx pi $ fun ctx inp =>
  (* Add a let-binding for the recursive [Repr] instance. *)
  with_rec_inst ctx pi (tVar fix_param) $ fun ctx rec_inst =>
  (* Build the match. *)
  let body := build_match ctx pi inp ctor_names in
  (* Abstract over all the variables. *)
  mk_fix ctx fix_param (pred $ List.length (input_vars inp)) $
    mk_lambdas ctx (input_vars inp) $ 
      mk_lets ctx [rec_inst] body.

(** [build_inst ctx pi func] builds the [Repr] instance corresponding 
    to the raw function [func]. *)
Definition build_inst ctx (pi : packed_inductive) (func : term) : term :=
  with_func_inputs ctx pi $ fun ctx inp =>
  mk_lambdas ctx (input_inst_vars inp) $
    let contents := mkApps func $ List.map tVar $ input_inst_vars inp in
    mkApps quoted_Build_Repr [apply_ind pi inp; contents].

(** * Effectful code. *)

(** Small helper function to deal with universe issues. *)
Definition unquote_func (func_ty : Type) (func : term) : TemplateMonad func_ty := 
  tmUnquoteTyped func_ty func.

(** [lookup_packed_inductive t] gathers in a [packed_inductive] the data
    pertaining to the inductive [t]. This assumes [t] is of the form [tInd _ _],
    i.e. it is not applied to any parameters or indices. *)
Definition lookup_packed_inductive {A} (raw_ind : A) : TemplateMonad packed_inductive :=
  (* Get the inductive. *)
  mlet (env, quoted_ind) <- tmQuoteRec raw_ind ;;
  mlet ind <- 
    match quoted_ind with 
    | tInd ind _ => ret ind
    | _ => tmFail "Not an inductive."%bs
    end
  ;; 
  (* Get the inductive body. *)
  mlet (mind_body, ind_body) <- 
    match lookup_inductive env ind with 
    | None => tmFail "Inductive is not declared."%bs
    | Some bodies => ret bodies 
    end 
  ;;
  (* Pack everything. *)
  ret {| pi_ind := ind ; pi_body := ind_body ; pi_mbody := mind_body |}.
  
(** Derive command entry-point. *)
Definition derive {A} (hints : hint_locality) (raw_ind : A) : TemplateMonad unit :=
  (* Lookup the inductive. *)
  mlet pi <- lookup_packed_inductive raw_ind ;;
  (* Check it is not a mutual inductive. *)
  mlet _ <- 
    match pi.(pi_mbody).(ind_bodies) with
    | _ :: _ :: _=> tmFail "Mutual inductives are not supported."%bs
    | _ => ret tt
    end
  ;;
  (* Quote the constructor names. For efficiency reasons we do this 
     at the toplevel, in order to keep as much code outside of TemplateMonad. *)
  let ctor_names :=
    List.map (fun pc => tString $ pstring_of_bytestring pc.(pc_body).(cstr_name)) (pi_ctors pi)
  in
  (* Build the raw function, choosing the right version. *)
  mlet build_func <-
    match pi.(pi_mbody).(ind_finite) with 
    | BiFinite => ret build_func_normal 
    | Finite => 
      (* For inductives, we only need a fixpoint if the inductive is recursive. *)
      tmPrint =<< tmEval cbv (is_pi_recursive pi) ;;
      ret $ if is_pi_recursive pi then build_func_fix else build_func_normal
    | CoFinite => tmFail "CoInductives are not supported."%bs 
    end
  ;;
  let quoted_func := build_func NamedCtx.empty pi ctor_names in
  (* Solve evars using unquoting. *)
  mlet func_ty <- tmUnquoteTyped Type (build_func_ty NamedCtx.empty pi) ;;
  mlet func <- unquote_func func_ty quoted_func ;;
  (* Package the raw function using [Build_Repr]. *)
  mlet quoted_func <- tmQuote func ;;
  let inst := build_inst NamedCtx.empty pi quoted_func in
  (* Add the instance to the global environment. *)
  let inst_name := ("repr_" ++ pi.(pi_body).(ind_name))%bs in
  tmMkDefinition inst_name inst ;;
  (* Declare it as an instance of [Repr]. *)
  mlet inst_ref <- tmLocate1 inst_name ;;
  tmExistingInstance hints inst_ref.

Definition derive_local {A} := @derive A local. 
Definition derive_global {A} := @derive A global. 
Definition derive_export {A} := @derive A export. 

(** TESTING *)

(*Instance repr_bool : Repr bool :=
{ repr_doc _ b := if b then str "true" else str "false" }.

Monomorphic Inductive bool_option := 
  | B1 : bool_option
  | B2 : bool -> bool_option.
Monomorphic Inductive mylist (A : Type) :=
  | MyNil : mylist A
  | MyCons : A -> mylist A -> mylist A.
Monomorphic Inductive myind (A B : Type) : Type := 
  | MyConstr : bool -> A -> myind A bool -> myind A B.
Monomorphic Inductive empty_vec : nat -> Type :=
  | EVNil : empty_vec 0
  | EVCons : forall n, empty_vec n -> empty_vec (S n).
Polymorphic Inductive poption (A : Type) :=
  | PNone : poption A
  | PSome : A -> poption A. 
Record color := { red : bool ; blue : bool ; green : bool }.

Unset MetaCoq Strict Unquote Universe Mode.
MetaCoq Run (derive_export option).
MetaCoq Run (derive_export list).
MetaCoq Run (derive_export color).*)
