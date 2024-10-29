(** This file implements a Coq command that automatically derives [Repr] instances
    for inductives and records. *)

From Coq Require Import PrimString List.
From MetaCoq.Template Require Import All Pretty.
From MetaCoq.Utils Require Import monad_utils.
From PPrint Require Import All.
From Repr Require Import Class Utils LocallyNameless Class.
From ReductionEffect Require Import PrintingEffect.

Import ListNotations MCMonadNotation.
Open Scope list_scope.

Set Universe Polymorphism.

(** Pretty-print the constructor argument [arg]. *)
Definition repr_arg {A} `{Repr A} (arg : A) : doc unit :=
  repr_doc (S app_precedence) arg.

(** Pretty-print the application of constructor [label] to a list of arguments [args].
    Due to a bug in MetaCoq it is impossible to quote primitive strings : [repr_ctor] thus
    takes in a bytestring instead, and performs the conversion everytime it is called. 
    This is obviously slightly inefficient.  *)
Definition repr_ctor (min_prec : nat) (label : bstring) (args : list (doc unit)) : doc unit :=
  (*let res := separate (break 1) (str label :: args) in*)
  let label := pstring_of_bytestring label in
  let res := 
    match args with 
    | [] => str label
    | _ => paren_if min_prec app_precedence $ flow (break 1) (str label :: args) 
    end
  in
  group $ hang 2 res.

(** SCRATCH *)


Instance repr_nat : Repr nat.
Admitted.

Instance repr_list {A} `{Repr A} : Repr (list A) :=
{
  repr_doc _ l := 
    let contents := flow_map (str ";" ^^ break 1) (repr_doc 0) l in
    group $ bracket "[" contents "]"
}.

Monomorphic Inductive vec A : nat -> Type :=
  | VNil : vec A 0
  | VCons : forall n, A -> vec A n -> vec A (S n).

Fixpoint repr_vec (A : Type) n (_ : Repr A) (prec : nat) (xs : vec A n) {struct xs} : doc unit :=
  let inst A' n' RA' := Build_Repr _ (repr_vec A' n' RA') in
  match xs with 
  | VNil => repr_ctor prec "VNil"%bs []
  | VCons n x xs => repr_ctor prec "VCons"%bs [repr_arg n; repr_arg x; repr_arg xs]
  end.

Monomorphic Inductive tree A : nat -> A -> Type :=
  | Leaf : forall a : A, tree A 0 a 
  | Node : forall a n m, A -> tree (list A) n [a] -> tree A m a -> tree A (n + m) a.
Arguments Leaf {A}.
Arguments Node {A}.
  
Definition repr_tree :=
  fix f 
    (A : Type) 
    (n : nat) (a : A) 
    (RA : Repr A) 
    (prec : nat) (xs : tree A n a) {struct xs} : doc unit :=
    let _ := fun (A' : Type) (n' : nat) (a' : A') (RA' : Repr A') => Build_Repr _ (f A' n' a' RA') in 
    match xs with 
    | Leaf a => repr_ctor prec "Leaf"%bs [repr_arg a]
    | Node a n m x l r => repr_ctor prec "Node"%bs [repr_arg a ; repr_arg n; repr_arg m ; repr_arg x; repr_arg l; repr_arg r]
    end.

(*Definition repr_tree' {A} {RA : Repr A} : Repr (tree A) := Build_Repr _ (repr_tree A RA).
Existing Instance repr_tree'.

Instance : Repr bool := { repr_doc b := if b then str "true" else str "false" }.

Eval compute in repr $ Node true (Node [true; false; true] Leaf Leaf) (Node false Leaf Leaf).*)

(** END SCRATCH *)

(** Quote some terms that we will need below. *)
MetaCoq Quote Definition quoted_repr_arg := (@repr_arg).
MetaCoq Quote Definition quoted_repr_ctor := (@repr_ctor).
MetaCoq Quote Definition quoted_doc_unit := (doc unit).
MetaCoq Quote Definition quoted_nil := (@nil).
MetaCoq Quote Definition quoted_cons := (@cons).
MetaCoq Quote Definition quoted_nat := (nat).
MetaCoq Quote Definition quoted_Repr := (Repr).
MetaCoq Quote Definition quoted_Build_Repr := (Build_Repr).

(** [term_list ty xs] builds the term corresponding to the list [x1; ...; xn], 
    assuming each [xi] has type [ty]. *)
Fixpoint term_list (ty : term) (xs : list term) : term :=
  match xs with 
  | [] => mkApp quoted_nil ty
  | x :: xs => mkApps quoted_cons [ty; x; term_list ty xs]
  end.

(** [with_ind_vars ctx ind ind_body k] calls the continuation [k] 
    with an extended context which contains :
    - declarations for the parameters of the inductive [ind].
    - declarations for the indices of the inductive [ind].
    - declarations for instances of [Repr] for each parameter (not for indices).

    This is a common pattern that is reused several times below. *)
Definition with_ind_vars {T} ctx (ind_body : one_inductive_body) 
  (k : NamedCtx.t -> list ident -> list ident -> list ident -> T) : T :=
  (* Declare the inductive parameters. *)
  with_ind_params ctx ind_body $ fun ctx params =>
  let param_terms := List.map tVar params in
  (* Declare the inductive indices. *)
  with_ind_indices ctx ind_body param_terms $ fun ctx indices =>
  (* Declare a Repr instance for each parameter. *)
  let repr_decls := List.map (fun p => mk_decl "H"%bs $ mkApp quoted_Repr p) param_terms in
  with_decls ctx repr_decls $ fun ctx param_insts =>
    (* Call the continuation. *)
    k ctx params indices param_insts.

(** Build a single argument. *)
Definition build_arg ctx (arg : ident) : term :=
  (* I use an evar in place of the [Repr] instance, which will be solved when unquoting the term. *)
  let evar := fresh_evar ctx in
  (*let evar := mkApp quoted_evar_axiom $ mkApp quoted_Repr $ NamedCtx.get_type ctx arg in*)
  ret $ mkApps quoted_repr_arg [NamedCtx.get_type ctx arg; evar; tVar arg].

(** Build a branch for a single constructor. *)
Definition build_branch ctx (ind : term) (params : list term) (prec : term)
  (ctor_body : constructor_body) (quoted_ctor_name : term) : branch term :=
  (* Get the list of arguments of the constructor. *)
  with_ctor_args ctx ctor_body ind params $ fun ctx args =>
  (* Apply [repr_ctor] to the precedence, label and the arguments. *)
  let repr_args := term_list quoted_doc_unit $ List.map (build_arg ctx) args in
  mk_branch ctx args $ mkApps quoted_repr_ctor [prec; quoted_ctor_name; repr_args].

(* fun (A' : Type) (H' : Repr A') => Build_Repr (mylist A') (fix_param A' H') *)

(** Bind the recursive [Repr] instance. *)
Definition with_rec_inst {T} ctx (ind_body : one_inductive_body) (ind : term) (fix_param : term) (k : NamedCtx.t -> ident -> T) : T :=
  let (ty, body) := 
    with_ind_vars ctx ind_body $ fun ctx params indices param_insts =>
    let I := mkApps ind $ List.map tVar $ params ++ indices in
    let body := mkApps fix_param $ List.map tVar $ params ++ indices ++ param_insts in
    ( mk_prods ctx (params ++ indices ++ param_insts) $ mkApp quoted_Repr I
    , mk_lambdas ctx (params ++ indices ++ param_insts) $ mkApps quoted_Build_Repr [I ; body])
  in 
  let decl := 
    {| decl_name := {| binder_name := nNamed "rec_inst"%bs ; binder_relevance := Relevant |}
    ;  decl_type := ty
    ;  decl_body := Some body |}
  in
  with_decl ctx decl k.

(** Build the case expression. *)
Definition build_match ctx (ind : inductive) (ind_body : one_inductive_body) (uinst : Instance.t)
  (params : list term) (x : term) (ctor_names : list term) (prec : term) : term :=
  (* Case info. *)  
  let ci := {| ci_ind := ind ; ci_npar := List.length params ; ci_relevance := Relevant |} in
  (* Case predicate. *)
  let pred := 
    with_ind_indices ctx ind_body params $ fun ctx indices =>
    with_decl ctx (mk_decl "x"%bs $ mkApps (tInd ind uinst) params) $ fun ctx x => 
      mk_pred ctx params indices x quoted_doc_unit
  in
  (* Case branches. *)
  let branches := map2 (build_branch ctx (tInd ind uinst) params prec) ind_body.(ind_ctors) ctor_names in
  (* Result. *)
  tCase ci pred x branches.

(** Build the raw function's type. *)
Definition build_func_ty ctx (ind : inductive) (ind_body : one_inductive_body) (uinst : Instance.t) : term :=
  with_ind_vars ctx ind_body $ fun ctx params indices param_insts =>
  (* Declare the precedence and inductive element. *)
  with_decl ctx (mk_decl "min_prec"%bs quoted_nat) $ fun ctx prec =>
  let I := mkApps (tInd ind uinst) $ List.map tVar $ params ++ indices in
  with_decl ctx (mk_decl "x"%bs I) $ fun ctx x =>
  (* Make the final product. *)
  mk_prods ctx (params ++ indices ++ param_insts ++ [prec; x]) quoted_doc_unit.

(** Build the raw function. *)
Definition build_func ctx (ind : inductive) (ind_body : one_inductive_body) (ctor_names : list term) 
  (uinst : Instance.t) : term :=
  (* Declare the fixpoint parameter. *)
  with_decl ctx (mk_decl "fix_param"%bs $ build_func_ty ctx ind ind_body uinst) $ fun ctx fix_param =>
  (* Declare the inductive parameters, indices and [Repr] instances. *)
  with_ind_vars ctx ind_body $ fun ctx params indices param_insts =>
  (* Declare the minimum precedence [min_prec]. *)
  with_decl ctx (mk_decl "min_prec"%bs quoted_nat) $ fun ctx prec =>
  (* Declare the input parameter [x]. *)
  let I := mkApps (tInd ind uinst) $ List.map tVar $ params ++ indices in
  with_decl ctx (mk_decl "x"%bs I) $ fun ctx x =>  
  (* Add a let-binding for the recursive [Repr] instance. *)
  with_rec_inst ctx ind_body (tInd ind uinst) (tVar fix_param) $ fun ctx rec_inst =>
  (* Build the match. *)
  let body := build_match ctx ind ind_body uinst (List.map tVar params) (tVar x) ctor_names (tVar prec) in
  (* Abstract over all the variables. *)
  mk_fix ctx fix_param (List.length params + List.length indices + List.length param_insts + 1) $
    mk_lambdas ctx (params ++ indices ++ param_insts ++ [prec; x]) $ 
      mk_lets ctx [rec_inst] body.
        
Definition unquote_func (func_ty : Type) (func : term) : TemplateMonad func_ty := 
  tmUnquoteTyped func_ty func.

Definition build_instance (env : global_env) (ind : inductive) : TemplateMonad unit :=
  (* Get the inductive body. *)
  mlet (mind_body, ind_body) <- 
    match lookup_inductive env ind with 
    | None => tmFail "Failed looking up the inductive body"%bs
    | Some bodies => ret bodies 
    end 
  ;;
  (* Quote the constructor names. *)
  mlet ctor_names <- 
    monad_map 
      (fun c => tmQuote =<< tmEval cbv c.(cstr_name)) 
      ind_body.(ind_ctors)
  ;;
  (* Build the function type. *)
  mlet func_ty <- tmUnquoteTyped Type (build_func_ty NamedCtx.empty ind ind_body []) ;;
  tmPrint "FUNC_TY"%pstring ;;
  tmPrint func_ty ;;
  (* Build the function term. *)
  let quoted_func := build_func NamedCtx.empty ind ind_body ctor_names [] in
  mlet func <- unquote_func func_ty quoted_func ;;
  tmPrint "FUNC"%pstring ;;
  tmPrint func.
  (* Quote again and add the definition. *)
  (*mlet quoted_func' <- tmQuote func ;;
  tmPrint quoted_func'.*)

(** Derive command entry-point. *)
Definition derive {A} (raw_ind : A) : TemplateMonad unit :=
  (* Get the inductive. *)
  mlet quoted_ind <- tmQuote raw_ind ;;
  mlet ind <- 
    match quoted_ind with 
    | tInd ind _ => ret ind
    | _ => tmFail "Not an inductive"%bs
    end
  ;; 
  (* Get the global environment needed to type the inductive. *)
  mlet env <- env_of_terms [quoted_ind; quoted_doc_unit; quoted_Repr] ;;
  (* Build the Repr instance. *)
  build_instance env ind.
  (*tmPrint =<< tmEval cbv (print_term (env, Monomorphic_ctx) [] true func) ;;*)
  (* Add the instance to the global environment and register it as an instance. *)
  (*tmMkDefinition "repr_derive"%bs func_ty*)
  
(** TESTING *)

Instance repr_bool : Repr bool :=
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

(* TODO : the evars are still not solved. *)
Unset MetaCoq Strict Unquote Universe Mode.
MetaCoq Run (derive tree).


(*Record color := { red : list nat * list nat ; green : list nat ; blue : list nat }. 

Instance reprColor : Repr color := 
{
  repr_doc c :=
    let fields := 
      [ ("red"  , repr_doc c.(red))
      ; ("green", repr_doc c.(green))
      ; ("blue" , repr_doc c.(blue))]
    in
    (* Pretty-print each field. *)
    let fields :=
      List.map (fun '(name, doc) => group (prefix 1 2 (str name ^^ str " :=") doc)) fields
    in
    (* Concatenate the fields (with semicolons). *)
    let contents := separate (str " ;" ^^ break 1) fields (*^^ ifflat empty (str " ;")*) in
    (* Add the leading and trailing brackets. *)
    let res := infix 1 2 (str "{|") contents (str "|}") in
    group (align res)
}.


Definition c_small := {| red := (range 2, range 0) ; green := range 3 ; blue := range 2 |}.
Definition c_large := {| red := (range 42, range 42) ; green := range 6 ; blue := range 2 |}.

Eval compute in repr c_small.
Eval compute in repr c_large.

Check 
{|
  red :=
    ([42; 41; 40; 39; 38; 37; 36; 35; 34; 33; 32; 31; 30; 29; 28; 27; 26; 25; 24;
      23; 22; 21; 20; 19; 18; 17; 16; 15; 14; 13; 12; 11; 10; 9; 8; 7; 6; 5; 4;
      3; 2; 1],
     [42; 41; 40; 39; 38; 37; 36; 35; 34; 33; 32; 31; 30; 29; 28; 27; 26; 25; 24;
      23; 22; 21; 20; 19; 18; 17; 16; 15; 14; 13; 12; 11; 10; 9; 8; 7; 6; 5; 4;
      3; 2; 1]) ;
  green := [6; 5; 4; 3; 2; 1] ;
  blue := [2; 1] ;
|}.

Eval compute in repr (range 42, List.map string_of_nat (range 26)).

Eval compute in String "034" "Hello".*)*)