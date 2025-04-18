(* *********************************************************************)
(*                                                                     *)
(*              The Compcert verified compiler                         *)
(*                                                                     *)
(*          Xavier Leroy, INRIA Paris-Rocquencourt                     *)
(*                                                                     *)
(*  Copyright Institut National de Recherche en Informatique et en     *)
(*  Automatique.  All rights reserved.  This file is distributed       *)
(*  under the terms of the INRIA Non-Commercial License Agreement.     *)
(*                                                                     *)
(* *********************************************************************)

(** The abstract domain for value numbering, used in common
    subexpression elimination. *)

Require Import Coqlib Maps.
Require Import AST Integers Values Memory Builtins Globalenvs Events.
Require Import Op Registers RTL.
Require Import ValueDomain.

(** Value numbers are represented by positive integers.  Equations are
  of the form [valnum = rhs] or [valnum >= rhs], where the right-hand
  sides [rhs] are either arithmetic operations or memory loads, [=] is
  strict equality of values, and [>=] is the "more defined than" relation
  over values. *)

Definition valnum := positive.

Inductive rhs : Type :=
  | Op: operation -> list valnum -> rhs
  | Load: memory_chunk -> addressing -> list valnum -> aptr -> rhs
  | Builtin: builtin_function -> list (builtin_arg valnum) -> rhs.

Inductive equation : Type :=
  | Eq (v: valnum) (strict: bool) (r: rhs).

Definition eq_valnum: forall (x y: valnum), {x=y}+{x<>y} := peq.

Definition eq_list_valnum: forall (x y: list valnum), {x=y}+{x<>y} := list_eq_dec peq.

(** Equality of [rhs] up to differences in regions attached to [Load] rhs. *)

Inductive rhs_compat: rhs -> rhs -> Prop :=
  | rhs_compat_op: forall op vl,
      rhs_compat (Op op vl) (Op op vl)
  | rhs_compat_load: forall chunk addr vl p1 p2,
      rhs_compat (Load chunk addr vl p1) (Load chunk addr vl p2)
  | rhs_compat_builtin: forall bf args,
      rhs_compat (Builtin bf args) (Builtin bf args).

Lemma rhs_compat_sym: forall rh1 rh2,
  rhs_compat rh1 rh2 -> rhs_compat rh2 rh1.
Proof.
  destruct 1; constructor; auto.
Qed.

Definition compat_rhs (r1 r2: rhs) : bool :=
  match r1, r2 with
  | Op op1 vl1, Op op2 vl2 => eq_operation op1 op2 && eq_list_valnum vl1 vl2
  | Load chunk1 addr1 vl1 p1, Load chunk2 addr2 vl2 p2 =>
      chunk_eq chunk1 chunk2 && eq_addressing addr1 addr2 && eq_list_valnum vl1 vl2
  | Builtin bf1 args1, Builtin bf2 args2 =>
      eq_builtin_function bf1 bf2 && list_eq_dec (eq_builtin_arg eq_valnum) args1 args2
  | _, _ => false
  end.

Lemma compat_rhs_sound: forall r1 r2,
  compat_rhs r1 r2 = true -> rhs_compat r1 r2.
Proof.
  unfold compat_rhs; intros; destruct r1, r2; try discriminate;
  InvBooleans; subst; constructor.
Qed.
  
(** A value numbering is a collection of equations between value numbers
  plus a partial map from registers to value numbers.  Additionally,
  we maintain the next unused value number, so as to easily generate
  fresh value numbers.  We also maintain a reverse mapping from value
  numbers to registers, redundant with the mapping from registers to
  value numbers, in order to speed up some operations. *)

Record numbering : Type := mknumbering {
  num_next: valnum;                  (**r first unused value number *)
  num_eqs: list equation;            (**r valid equations *)
  num_reg: PTree.t valnum;           (**r mapping register to valnum *)
  num_val: PMap.t (list reg)         (**r reverse mapping valnum to regs containing it *)
}.

Definition empty_numbering :=
  {| num_next := 1%positive;
     num_eqs  := nil;
     num_reg  := PTree.empty _;
     num_val  := PMap.init nil |}.

(** A numbering is well formed if all value numbers mentioned are below
  [num_next].  Moreover, the [num_val] reverse mapping must be consistent
  with the [num_reg] direct mapping. *)

Definition valnums_rhs (r: rhs): list valnum :=
  match r with
  | Op op vl => vl
  | Load chunk addr vl ap => vl
  | Builtin bf args => params_of_builtin_args args
  end.

Definition wf_rhs (next: valnum) (r: rhs) : Prop :=
  forall v, In v (valnums_rhs r) -> Plt v next.

Definition wf_equation (next: valnum) (e: equation) : Prop :=
  match e with Eq l str r => Plt l next /\ wf_rhs next r end.

Record wf_numbering (n: numbering) : Prop := {
  wf_num_eqs: forall e,
      In e n.(num_eqs) -> wf_equation n.(num_next) e;
  wf_num_reg: forall r v,
      PTree.get r n.(num_reg) = Some v -> Plt v n.(num_next);
  wf_num_val: forall r v,
      In r (PMap.get v n.(num_val)) -> PTree.get r n.(num_reg) = Some v
}.

Global Hint Resolve wf_num_eqs wf_num_reg wf_num_val: cse.

(** Satisfiability of numberings.  A numbering holds in a concrete
  execution state if there exists a valuation assigning values to
  value numbers that satisfies the equations and register mapping
  of the numbering. *)

Definition valuation := valnum -> val.

Inductive rhs_eval_to (valu: valuation) (ge: genv) (sp: val) (m: mem):
                                                     rhs -> val -> Prop :=
  | op_eval_to: forall op vl v,
      eval_operation ge sp op (map valu vl) m = Some v ->
      rhs_eval_to valu ge sp m (Op op vl) v
  | load_eval_to: forall chunk addr vl a v p,
      eval_addressing ge sp addr (map valu vl) = Some a ->
      Mem.loadv chunk m a = Some v ->
      rhs_eval_to valu ge sp m (Load chunk addr vl p) v
  | builtin_eval_to: forall bf args vargs v,
      eval_builtin_args ge valu sp m args vargs ->
      builtin_function_sem bf vargs = Some v ->
      rhs_eval_to valu ge sp m (Builtin bf args) v.

Lemma rhs_eval_to_compat: forall valu ge sp m rh v rh',
  rhs_eval_to valu ge sp m rh v ->
  rhs_compat rh rh' ->
  rhs_eval_to valu ge sp m rh' v.
Proof.
  intros. inv H; inv H0; econstructor; eauto.
Qed.

(** A [Load] equation carries a region (abstract pointer) [p],
    characterizing which part of memory is being read.
    The following predicate makes sure the actual address
    belongs to the given region. *)

Inductive rhs_valid (valu: valuation) (ge: genv): val -> rhs -> Prop :=
  | op_valid: forall sp op vl,
      rhs_valid valu ge sp (Op op vl)
  | load_valid: forall sp chunk addr vl p b ofs bc,
      eval_addressing ge (Vptr sp Ptrofs.zero) addr (map valu vl) = Some (Vptr b ofs) ->
      pmatch bc b ofs p -> genv_match bc ge -> bc sp = BCstack ->
      rhs_valid valu ge (Vptr sp Ptrofs.zero) (Load chunk addr vl p)
  | builtin_valid: forall sp bf args,
      rhs_valid valu ge sp (Builtin bf args).

Inductive equation_holds (valu: valuation) (ge: genv) (sp: val) (m: mem):
                                                      equation -> Prop :=
  | eq_holds_strict: forall l r,
      rhs_eval_to valu ge sp m r (valu l) ->
      rhs_valid valu ge sp r ->
      equation_holds valu ge sp m (Eq l true r)
  | eq_holds_lessdef: forall l r v,
      rhs_eval_to valu ge sp m r v -> Val.lessdef v (valu l) ->
      rhs_valid valu ge sp r ->
      equation_holds valu ge sp m (Eq l false r).

Record numbering_holds (valu: valuation) (ge: genv) (sp: val)
                       (rs: regset) (m: mem) (n: numbering) : Prop := {
  num_holds_wf:
     wf_numbering n;
  num_holds_eq: forall eq,
     In eq n.(num_eqs) -> equation_holds valu ge sp m eq;
  num_holds_reg: forall r v,
     n.(num_reg)!r = Some v -> rs#r = valu v
}.

Global Hint Resolve num_holds_wf num_holds_eq num_holds_reg: cse.

(** The initial value numbering, at function entry. *)

Lemma empty_numbering_holds:
  forall valu ge sp rs m,
  numbering_holds valu ge sp rs m empty_numbering.
Proof.
  intros; split; simpl; intros.
- split; simpl; intros.
  + contradiction.
  + rewrite PTree.gempty in H; discriminate.
  + contradiction.
- contradiction.
- rewrite PTree.gempty in H; discriminate.
Qed.

(** Simplification of comparisons when the two arguments have the same value number,
    and therefore are equal. *)

Definition combine_comparison (c: comparison) (x y: valnum) : option bool :=
  if eq_valnum x y then
    Some (match c with
            | Ceq | Cle | Cge => true
            | Cne | Clt | Cgt => false
          end)
  else
    None.

Lemma combine_comparison_cmp_sound:
  forall (valu: valnum -> val) c x y res res',
  combine_comparison c x y = Some res' ->
  Val.cmp_bool c (valu x) (valu y) = Some res ->
  res = res'.
Proof.
  unfold combine_comparison; intros. destruct (eq_valnum x y); inv H.
  destruct (valu y); simpl in H0; inv H0.
  destruct c; simpl; unfold Int.lt; rewrite ? Int.eq_true, ? zlt_false by lia; auto.
Qed.

Lemma combine_comparison_cmpu_sound:
  forall (valu: valnum -> val) m c x y res res',
  combine_comparison c x y = Some res' ->
  Val.cmpu_bool (Mem.valid_pointer m) c (valu x) (valu y) = Some res ->
  res = res'.
Proof.
  unfold combine_comparison, Val.cmpu_bool; intros. destruct (eq_valnum x y); inv H.
  destruct (valu y).
- discriminate.
- inv H0. destruct c; simpl; unfold Int.ltu; rewrite ? Int.eq_true, ? zlt_false by lia; auto.
- discriminate.
- discriminate.
- discriminate.
- destruct Archi.ptr64; try discriminate.
  rewrite dec_eq_true in H0. destruct andb in H0; inv H0.
  destruct c; simpl; unfold Ptrofs.ltu; rewrite ? Ptrofs.eq_true, ? zlt_false by lia; auto.
Qed.

Lemma combine_comparison_cmpl_sound:
  forall (valu: valnum -> val) c x y res res',
  combine_comparison c x y = Some res' ->
  Val.cmpl_bool c (valu x) (valu y) = Some res ->
  res = res'.
Proof.
  unfold combine_comparison; intros. destruct (eq_valnum x y); inv H.
  destruct (valu y); simpl in H0; inv H0.
  destruct c; simpl; unfold Int64.lt; rewrite ? Int64.eq_true, ? zlt_false by lia; auto.
Qed.

Lemma combine_comparison_cmplu_sound:
  forall (valu: valnum -> val) m c x y res res',
  combine_comparison c x y = Some res' ->
  Val.cmplu_bool (Mem.valid_pointer m) c (valu x) (valu y) = Some res ->
  res = res'.
Proof.
  unfold combine_comparison, Val.cmplu_bool; intros. destruct (eq_valnum x y); inv H.
  destruct (valu y).
- discriminate.
- discriminate.
- inv H0. destruct c; simpl; unfold Int64.ltu; rewrite ? Int64.eq_true, ? zlt_false by lia; auto.
- discriminate.
- discriminate.
- destruct (negb Archi.ptr64); try discriminate.
  rewrite dec_eq_true in H0. destruct andb in H0; inv H0.
  destruct c; simpl; unfold Ptrofs.ltu; rewrite ? Ptrofs.eq_true, ? zlt_false by lia; auto.
Qed.
