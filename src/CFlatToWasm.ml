open CFlat
open CFlat.Sizes

module W = Wasm
module K = Constant

module StringMap = Map.Make(String)

(******************************************************************************)
(* Environments                                                               *)
(******************************************************************************)

type env = {
  funcs: int StringMap.t;
    (** Mapping each function to its index in the function index space. *)
  globals: int StringMap.t;
    (** Mapping each global to its index in the global index space. *)
  n_args: int;
    (** The number of arguments to the current function. Needed to compute the
     * index of the four "scratch" variables that each function has (see dup32). *)
  strings: (string, int) Hashtbl.t;
    (** Mapping constant string literals to their offset relative to the start
     * of THIS module's data segment. *)
  data_size: int ref;
    (** The current size of THIS module's data segment. This field and the one
     * above are mutable, so as to lazily allocate string literals as we hit
     * them. *)
}

let empty = {
  funcs = StringMap.empty;
  globals = StringMap.empty;
  n_args = 0;
  strings = Hashtbl.create 41;
  data_size = ref 0
}

let find_global env name =
  StringMap.find name env.globals

let find_func env name =
  StringMap.find name env.funcs


(******************************************************************************)
(* Helpers                                                                    *)
(******************************************************************************)

(** We don't make any effort (yet) to keep track of positions even though Wasm
 * really wants us to. *)
let dummy_phrase what =
  W.Source.(what @@ no_region)

(** A bunch of helpers *)
let mk_var x = dummy_phrase (Int32.of_int x)

let mk_type = function
  | I32 ->
      W.Types.I32Type
  | I64 ->
      W.Types.I64Type

let mk_value s x =
  match s with
  | I32 ->
      W.Values.I32 x
  | I64 ->
      W.Values.I64 x

let mk_int32 i =
  dummy_phrase (W.Values.I32 i)

let mk_int64 i =
  dummy_phrase (W.Values.I64 i)

let mk_const c =
  [ dummy_phrase (W.Ast.Const c) ]

let mk_lit w lit =
  match w with
  | K.Int32 | K.UInt32 | K.Bool ->
      mk_int32 (Int32.of_string lit)
  | K.Int64 | K.UInt64 ->
      mk_int64 (Int64.of_string lit)
  | _ ->
      failwith "mk_lit"

let i32_mul =
  [ dummy_phrase (W.Ast.Binary (mk_value I32 W.Ast.IntOp.Mul)) ]

let i32_add =
  [ dummy_phrase (W.Ast.Binary (mk_value I32 W.Ast.IntOp.Add)) ]

let i32_and =
  [ dummy_phrase (W.Ast.Binary (mk_value I32 W.Ast.IntOp.And)) ]

let i32_sub =
  [ dummy_phrase (W.Ast.Binary (mk_value I32 W.Ast.IntOp.Sub)) ]

let i32_not =
  mk_const (mk_int32 Int32.one) @
  [ dummy_phrase (W.Ast.Binary (mk_value I32 W.Ast.IntOp.Xor)) ]

let i32_zero =
  mk_const (mk_int32 Int32.zero)

let i32_one =
  mk_const (mk_int32 Int32.one)

let mk_unit =
  i32_zero

let mk_drop =
  [ dummy_phrase W.Ast.Drop ]

(* Wasm lacks two crucial instructions: dup (to duplicate the operand at the
 * top of the stack) and swap (to swap the two topmost operands). There are some
 * macros, such as grow_highwater (or 16/8-bit arithmetic), that we want to
 * expand at the last minute (since they use some very low-level Wasm concepts).
 * Therefore, as a convention, every function frame has four "scratch" locals;
 * the first two of size I64; the last two of size I32. The Wasm register
 * allocator will take care of optimizing all of that. *)
let dup32 env =
  [ dummy_phrase (W.Ast.TeeLocal (mk_var (env.n_args + 2)));
    dummy_phrase (W.Ast.GetLocal (mk_var (env.n_args + 2))) ]

let dup64 env =
  [ dummy_phrase (W.Ast.TeeLocal (mk_var (env.n_args + 0)));
    dummy_phrase (W.Ast.GetLocal (mk_var (env.n_args + 0))) ]

let swap32 env =
  [ dummy_phrase (W.Ast.SetLocal (mk_var (env.n_args + 2)));
    dummy_phrase (W.Ast.SetLocal (mk_var (env.n_args + 3)));
    dummy_phrase (W.Ast.GetLocal (mk_var (env.n_args + 2)));
    dummy_phrase (W.Ast.GetLocal (mk_var (env.n_args + 3))) ]

let swap64 env =
  [ dummy_phrase (W.Ast.SetLocal (mk_var (env.n_args + 0)));
    dummy_phrase (W.Ast.SetLocal (mk_var (env.n_args + 1)));
    dummy_phrase (W.Ast.GetLocal (mk_var (env.n_args + 0)));
    dummy_phrase (W.Ast.GetLocal (mk_var (env.n_args + 1))) ]


(******************************************************************************)
(* Run-time memory management                                                 *)
(******************************************************************************)

(* We use a bump-pointer allocator called the "highwater mark". One can read it
 * (grows the stack by one); grow it by the specified offset (shrinks the stack
 * by one); restore a value into it (also shrinks the stack by one). *)

(* The highwater mark denotes the top of the stack (bump-pointer allocation).
 * Since it needs to be shared across modules, and since Wasm does not support
 * exported, mutable globals, we use the first word of the (shared) memory for
 * that purpose. *)
let read_highwater =
  i32_zero @
  [ dummy_phrase W.Ast.(Load { ty = mk_type I32; align = 0; offset = 0l; sz = None }) ]

let write_highwater env =
  i32_zero @
  swap32 env @
  [ dummy_phrase W.Ast.(Store { ty = mk_type I32; align = 0; offset = 0l; sz = None }) ]

let grow_highwater env =
  read_highwater @
  i32_add @
  write_highwater env


(******************************************************************************)
(* Static memory management (the data segment)                                *)
(******************************************************************************)

(* We want to store constant string literals in the data segment, for efficiency
 * reasons. Since all of our modules share the same linear memory, we proceed as
 * follows. Each module imports, in addition to Kremlin.mem, a constant known as
 * Kremlin.data_start. This module then lays out its strings in the data
 * segment, relative to data_start. Once all strings have been laid out, the
 * module exports its new data_size, and the loader grows Kremlin.data_start by
 * this module's data_size before loading the next module. *)
let compute_string_offset env rel_addr =
  [ dummy_phrase (W.Ast.GetGlobal (mk_var (find_global env "data_start"))) ] @
  [ dummy_phrase (W.Ast.Const (mk_int32 (Int32.of_int rel_addr))) ] @
  i32_add

let mk_string env s =
  let rel_addr =
    try Hashtbl.find env.strings s
    with Not_found ->
      (* Data segment computation will insert the final \000 byte. *)
      let l = String.length s + 1 in
      let rel_addr = !(env.data_size) in
      Hashtbl.add env.strings s rel_addr;
      env.data_size := rel_addr + l;
      rel_addr
  in
  compute_string_offset env rel_addr
  

(******************************************************************************)
(* Arithmetic                                                                 *)
(******************************************************************************)

let todo w =
  match w with
  | K.Int8 | K.Int16 -> failwith "todo"
  | _ -> ()

(** Binary operations take a width and an operation, in order to pick the right
 * flavor of signed vs. unsigned operation *)
let mk_binop (w, o) =
  let open W.Ast.IntOp in
  match o with
  | K.Add | K.AddW ->
      Some Add
  | K.Sub | K.SubW ->
      Some Sub
  | K.Div | K.DivW ->
      todo w;
      (* Fortunately, it looks like FStar.Int*, C and Wasm all adopt the
       * "rounding towards zero" behavior. Phew! *)
      if K.is_signed w then
        Some DivS
      else
        Some DivU
  | K.Mult | K.MultW ->
      Some Mul
  | K.Mod ->
      todo w;
      if K.is_signed w then
        Some RemS
      else
        Some RemU
  | K.BOr | K.Or ->
      Some Or
  | K.BAnd | K.And ->
      Some And
  | K.BXor | K.Xor ->
      Some Xor
  | K.BShiftL ->
      Some Shl
  | K.BShiftR ->
      todo w;
      if K.is_signed w then
        Some ShrS
      else
        Some ShrU
  | _ ->
      None

let is_binop (o: K.width * K.op) =
  mk_binop o <> None

let mk_cmpop (w, o) =
  let open W.Ast.IntOp in
  match o with
  | K.Eq ->
      Some Eq
  | K.Neq ->
      Some Ne
  | K.BNot | K.Not ->
      failwith "todo not (zero minus?)"
  | K.Lt ->
      todo w;
      if K.is_signed w then
        Some LtS
      else
        Some LtU
  | K.Lte ->
      todo w;
      if K.is_signed w then
        Some LeS
      else
        Some LeU
  | K.Gt ->
      todo w;
      if K.is_signed w then
        Some GtS
      else
        Some GtU
  | K.Gte ->
      todo w;
      if K.is_signed w then
        Some GeS
      else
        Some GeU
  | _ ->
      None

let is_cmpop (o: K.width * K.op) =
  mk_cmpop o <> None

(** Dealing with size mismatches *)

(** The delicate question is how to handle integer types < 32 bits. Two options
 * for signed integers:
 * - keep the most significant bit as the sign bit (i.e; the 32nd bit), and use
 *   the remaining lowest n-1 bits; this means that operations that need to care
 *   about the sign (shift-right, division, remainder) can be builtin Wasm
 *   operations; then, assuming we want to replicate the C semantics:
 *   - signed to larger signed = no-op
 *   - signed to smaller signed = mask & shift sign bit
 *   - unsigned to smaller unsigned = mask
 *   - unsigned to larger unsigned = no-op
 *   - signed to smaller unsigned = mask
 *   - signed to equal or greater unsigned = shift sign bit
 *   - unsigned to smaller or equal signed = mask & shift sign bit
 *   - unsigned to larger signed = no-op
 * - use the lowest n bits and re-implement "by hand" operations that require us
 *   to care about the sign
 *   - signed to larger signed = sign-extension
 *   - signed to smaller signed = mask
 *   - unsigned to smaller unsigned = mask
 *   - unsigned to larger unsigned = no-op
 *   - signed to smaller unsigned = mask
 *   - signed to greater unsigned = sign-extension
 *   - unsigned to smaller or equal signed = mask
 *   - unsigned to larger signed = no-op
 *)
let mk_mask w =
  let open K in
  match w with
  | UInt32 | Int32 | UInt64 | Int64 | UInt | Int ->
      []
  | UInt16 | Int16 ->
      mk_const (mk_int32 0xffffl) @
      i32_and
  | UInt8 | Int8 ->
      mk_const (mk_int32 0xffl) @
      i32_and
  | _ ->
      []

let mk_cast w_from w_to =
  let open K in
  match w_from, w_to with
  | (UInt8 | UInt16 | UInt32), (Int64 | UInt64 | Int | UInt) ->
      (* Zero-padding, C semantics. That's 12 cases. *)
      [ dummy_phrase (W.Ast.Convert (W.Values.I32 W.Ast.IntOp.ExtendUI32)) ]
  | Int32, (Int64 | UInt64 | Int | UInt) ->
      (* Sign-extend, then re-interpret, also C semantics. That's 12 more cases. *)
      [ dummy_phrase (W.Ast.Convert (W.Values.I32 W.Ast.IntOp.ExtendSI32)) ]
  | (Int64 | UInt64 | Int | UInt), (Int32 | UInt32) ->
      (* Truncate, still C semantics (famous last words?). That's 24 cases. *)
      [ dummy_phrase (W.Ast.Convert (W.Values.I64 W.Ast.IntOp.WrapI64)) ] @
      mk_mask w_to
  | (Int8 | UInt8), (Int8 | UInt8)
  | (Int16 | UInt16), (Int16 | UInt16)
  | (Int32 | UInt32), (Int32 | UInt32)
  | (Int64 | UInt64), (Int64 | UInt64) ->
      []
  | UInt8, (UInt16 | UInt32)
  | UInt16, UInt32 ->
      []
  | UInt16, UInt8
  | UInt32, (UInt16 | UInt8) ->
      mk_mask w_to
  | Bool, _ | _, Bool ->
      invalid_arg "mk_cast"
  | _ ->
      failwith "todo: signed cast conversions"


(******************************************************************************)
(* Debugging                                                                  *)
(******************************************************************************)

module Debug = struct

  (** This module provides a set of helpers to insert debugging within the
   * instruction stream. *)

  (* Debugging conventions. We assume some scratch space at the beginning of the
   * memory; bytes 0..3 are the highwater mark, and bytes 4..127 are scratch space
   * to write a series of either:
   * - 1 followed by the address of a zero-terminated string (most likely sitting
   *     in the data segment), or
   * - 2 followed by a 32-bit integer (little-endian, as enforced by Wasm), or
   * - 3 followed by a 64-bit integer (little-endian, as enforced by Wasm), or
   * - 4 increase nesting of call stack, or
   * - 5 decrease nesting of call stack, or
   * - 0 (end of transmission)
   * This is to be read by the (externally-provided) debug function. This space
   * may evolve to include more information. The debug function is always the
   * function imported first (to easily generate debugging code). *)
  let mark_size = 4

  (* Debugging requires only one import, namely the debug function. We could've
   * done things differently, but since Wasm does not support varargs, it
   * would've been hard to write a generic printing routine otherwise. TODO:
   * this info could be written right after the highwater mark, that way, we
   * wouldn't be limited to 124b of debugging info. *)
  let default_imports = [
    dummy_phrase W.Ast.({
      module_name = "Kremlin";
      item_name = "debug";
      ikind = dummy_phrase (FuncImport (mk_var 0))
    })
  ]

  let default_types = [
    W.Types.FuncType ([], [])
  ]

  let mk env l =

    let char ofs c =
      let c = Char.code c in
      mk_const (mk_int32 (Int32.of_int ofs)) @
      mk_const (mk_int32 (Int32.of_int c)) @
      [ dummy_phrase W.Ast.(Store {
          ty = mk_type I32; align = 0; offset = 0l; sz = Some W.Memory.Mem8 })]
    in

    let rec byte_and_store ofs c t instr tl =
      char ofs c @
      mk_const (mk_int32 (Int32.of_int (ofs + 1))) @
      instr @
      [ dummy_phrase W.Ast.(Store {
          ty = mk_type t; align = 0; offset = 0l; sz = None })] @
      aux (if t = I32 then ofs + 5 else ofs + 9) tl

    and aux ofs l =
      match l with
      | [] ->
          if ofs > 127 then
            failwith "Debug information clobbered past the scratch area";
          char ofs '\x00'
      | `String s :: tl ->
          byte_and_store ofs '\x01' I32 (mk_string env s) tl
      | `Peek32 :: tl ->
          byte_and_store ofs '\x02' I32 (dup32 env) tl
      | `Local32 i :: tl ->
          byte_and_store ofs '\x02' I32 [ dummy_phrase (W.Ast.GetLocal (mk_var i)) ] tl
      | `Peek64 :: tl ->
          byte_and_store ofs '\x02' I64 (dup64 env) tl
      | `Local64 i :: tl ->
          byte_and_store ofs '\x02' I64 [ dummy_phrase (W.Ast.GetLocal (mk_var i)) ] tl
      | `Incr :: tl ->
          char ofs '\x04' @
          aux (ofs + 1) tl
      | `Decr :: tl ->
          char ofs '\x05' @
          aux (ofs + 1) tl
    in
    if Options.debug "wasm-calls" then
      aux mark_size l @
      [ dummy_phrase (W.Ast.Call (mk_var (find_func env "debug"))) ]
    else
      []
end


(******************************************************************************)
(* Initial imports for all modules                                            *)
(******************************************************************************)

module Base = struct
  (* Reminder: the JS loader, as it folds over the list of modules, provides
   * each module with the start address of its own data segment. *)
  let data_start =
    dummy_phrase W.Ast.({
      module_name = "Kremlin";
      item_name = "data_start";
      ikind = dummy_phrase (GlobalImport W.Types.(
        GlobalType (mk_type I32, Immutable)))})

  let memory =
    let mtype = W.Types.MemoryType W.Types.({ min = 16l; max = None }) in
    dummy_phrase W.Ast.({
      module_name = "Kremlin";
      item_name = "mem";
      ikind = dummy_phrase (MemoryImport mtype)})

  (* This establishes the func index / type index invariant. *)
  let imports = memory :: data_start :: Debug.default_imports
  let types = Debug.default_types
end


(******************************************************************************)
(* Actual translation from Cflat to Wasm                                      *)
(******************************************************************************)

let rec mk_callop2 env (w, o) e1 e2 =
  (* TODO: check special byte semantics C / WASM *)
  let size = size_of_width w in
  mk_expr env e1 @
  mk_expr env e2 @
  if is_binop (w, o) then
    [ dummy_phrase (W.Ast.Binary (mk_value size (Option.must (mk_binop (w, o))))) ] @
    mk_mask w
  else if is_cmpop (w, o) then
    [ dummy_phrase (W.Ast.Compare (mk_value size (Option.must (mk_cmpop (w, o))))) ] @
    mk_mask w
  else
    failwith "todo mk_callop2"

and mk_size size =
  [ dummy_phrase (W.Ast.Const (mk_int32 (Int32.of_int (bytes_in size)))) ]

and mk_expr env (e: expr): W.Ast.instr list =
  match e with
  | Var i ->
      [ dummy_phrase (W.Ast.GetLocal (mk_var i)) ]

  | Constant (w, lit) ->
      mk_const (mk_lit w lit)

  | CallOp (o, [ e1; e2 ]) ->
      mk_callop2 env o e1 e2

  | CallFunc (name, es) ->
      KList.map_flatten (mk_expr env) es @
      [ dummy_phrase (W.Ast.Call (mk_var (find_func env name))) ]

  | BufCreate (Common.Stack, n_elts, elt_size) ->
      (* TODO semantics discrepancy the size is a uint32 both in Low* and Wasm
       * but Low* talks about the number of elements while Wasm talks about the
       * number of bytes *)
      read_highwater @
      mk_expr env n_elts @
      mk_size elt_size @
      i32_mul @
      grow_highwater env

  | BufRead (e1, e2, size) ->
      (* github.com/WebAssembly/spec/blob/master/interpreter/spec/eval.ml#L189 *)
      mk_expr env e1 @
      mk_expr env e2 @
      mk_size size @
      i32_mul @
      i32_add @
      [ dummy_phrase W.Ast.(Load {
        (* the type we want on the operand stack *)
        ty = mk_type (if size = A64 then I64 else I32); 
        (* ignored *)
        align = 0;
        (* we've already done the multiplication ourselves *)
        offset = 0l;
        (* we store 32-bit integers in 32-bit slots, and smaller than that in
         * 32-bit slots as well, so no conversion M32 for us *)
        sz = match size with
          | A16 -> Some W.Memory.(Mem16, ZX)
          | A8 -> Some W.Memory.(Mem8, ZX)
          | _ -> None })]

  | BufSub (e1, e2, size) ->
      mk_expr env e1 @
      mk_expr env e2 @
      mk_size size @
      i32_mul @
      i32_add

  | Cast (e1, w_from, w_to) ->
      mk_expr env e1 @
      mk_cast w_from w_to

  | IfThenElse (e, b1, b2, s) ->
      let s = mk_type s in
      mk_expr env e @
      [ dummy_phrase (W.Ast.If ([ s ], mk_expr env b1, mk_expr env b2)) ]

  | Assign (i, e) ->
      mk_expr env e @
      [ dummy_phrase (W.Ast.SetLocal (mk_var i)) ] @
      mk_unit

  | BufWrite (e1, e2, e3, size) ->
      mk_expr env e1 @
      mk_expr env e2 @
      mk_size size @
      i32_mul @
      i32_add @
      mk_expr env e3 @
      [ dummy_phrase W.Ast.(Store {
        ty = mk_type (if size = A64 then I64 else I32); 
        align = 0;
        offset = 0l;
        sz = match size with
          | A16 -> Some W.Memory.Mem16
          | A8 -> Some W.Memory.Mem8
          | _ -> None })] @
      mk_unit

  | While (e, expr) ->
      [ dummy_phrase (W.Ast.Loop ([],
        mk_expr env e @
        [ dummy_phrase (W.Ast.If ([],
          mk_expr env expr @ mk_drop @ [ dummy_phrase (W.Ast.Br (mk_var 1)) ],
          [ dummy_phrase W.Ast.Nop ])) ]
      ))] @
      mk_unit

  | Ignore (e, _) ->
      mk_expr env e @
      mk_drop

  | Sequence es ->
      let es, e = KList.split_at_last es in
      List.flatten (List.map (fun e ->
        mk_expr env e @
        [ dummy_phrase W.Ast.Drop ]
      ) es) @
      mk_expr env e

  | PushFrame ->
      read_highwater @
      mk_unit

  | PopFrame ->
      write_highwater env @
      mk_unit

  | _ ->
      failwith ("not implemented; got: " ^ show_expr e)

let mk_func_type { args; ret; _ } =
  W.Types.( FuncType (
    List.map mk_type args,
    List.map mk_type ret))

let mk_func env { args; locals; body; name; ret; _ } =
  let i = find_func env name in
  let env = { env with n_args = List.length args } in

  let body =
    (* Mostly a bunch of debugging info. *)
    let debug_enter = `String name :: `Incr ::
      List.mapi (fun i arg ->
        match arg with
        | I32 ->
            `Local32 i
        | I64 ->
            `Local64 i
      ) args
    in
    let debug_exit = [ `String "return"; `Decr ] @
      match ret with
      | [ I32 ] -> [ `Peek32 ]
      | [ I64 ] -> [ `Peek64 ]
      | _ -> []
    in
    Debug.mk env debug_enter @
    mk_expr env body @
    Debug.mk env debug_exit
  in
  let locals = List.map mk_type locals in
  let ftype = mk_var i in
  dummy_phrase W.Ast.({ locals; ftype; body })

let mk_global env size body =
  let body = mk_expr env body in
  dummy_phrase W.Ast.({
    gtype = W.Types.GlobalType (mk_type size, W.Types.Immutable);
    value = dummy_phrase body
  })


(******************************************************************************)
(* Putting it all together: generating a Wasm module                          *)
(******************************************************************************)

(* From [types] (all the function types in the universe) and [imports] (some
 * globals, a memory, and exactly [List.length types] functions who come in the
 * same order as [types]), build a current module; as a bonus, grow [types] and
 * [imports] with the exports from this module. *)
let mk_module types imports (name, decls):
  W.Types.func_type list * W.Ast.import list * (string * W.Ast.module_) =

  (* Layout the import and types for the current module. The current module's
   * types start with [types]; the current module's imports starts with
   * [imports]. We fold over these to build our environment's maps, which
   * associate to each function & global an index. The Wasm function
   * (resp. globals) index space is made up of all the imported functions (resp.
   * globals), then the current module's functions (resp. globals). *)
  let rec assign env f g imports =
    (* We have seen [f] functions and [g] globals. *)
    match imports with
    | { W.Source.it = { W.Ast.item_name; ikind = { W.Source.it = W.Ast.FuncImport n; _ }; _ }; _ } :: tl ->
        let env = { env with funcs = StringMap.add item_name f env.funcs } in
        assert (Int32.to_int n.W.Source.it = f);
        assign env (f + 1) g tl
    | { W.Source.it = { W.Ast.item_name; ikind = { W.Source.it = W.Ast.GlobalImport _; _ }; _ }; _ } :: tl ->
        let env = { env with globals = StringMap.add item_name g env.globals } in
        assign env f (g + 1) tl
    | _ :: tl ->
        (* Intentionally skipping other imports (e.g. memory). *)
        assign env f g tl
    | [] ->
        f, g, env
  in
  let n_imported_funcs, n_imported_globals, env = assign empty 0 0 imports in

  (* Continue filling our environment with the rest of the function (resp.
   * global) index space, namely, this module's functions (resp. globals) *)
  let rec assign env f g = function
    | Function { name; _ } :: tl ->
        let env = { env with funcs = StringMap.add name f env.funcs } in
        assign env (f + 1) g tl
    | Global (name, _, _, _) :: tl -> 
        let env = { env with globals = StringMap.add name g env.globals } in
        assign env f (g + 1) tl
    | _ :: tl ->
        (* Intentionally skipping type declarations. *)
        assign env f g tl
    | [] ->
        env
  in
  let env = assign env n_imported_funcs n_imported_globals decls in

  (* Generate types for the function declarations. Re-establish the invariant
   * that the function at index i in the function index space has type i in the
   * types index space. *)
  let types = types @ KList.filter_map (function
    | Function f ->
        Some (mk_func_type f)
    | _ ->
        None
  ) decls in

  (* Compile the functions. *)
  let funcs = KList.filter_map (function
    | Function f ->
        Some (mk_func env f)
    | _ ->
        None
  ) decls in

  (* The globals, too *)
  let globals =
    KList.filter_map (function
      | Global (_, size, body, _) ->
          Some (mk_global env size body)
      | _ ->
          None
    ) decls
  in

  (* Now, this means that we can easily extend [imports] with our own functions
   * & globals, to be passed to the next module when they want to import all the
   * stuff in the universe, including the current module's "stuff". Note: this
   * maintains the invariant that the i-th function in [imports_me_included]
   * points to type index i. *)
  let imports_me_included = imports @ KList.filter_map (function
    | Function f ->
        Some (dummy_phrase W.Ast.({
          module_name = name;
          item_name = f.name;
          ikind = dummy_phrase (FuncImport (mk_var (find_func env f.name)))
        }))
    | Global (g_name, size, _, _) ->
        let t = mk_type size in
        Some (dummy_phrase W.Ast.({
          module_name = name;
          item_name = g_name;
          ikind = dummy_phrase (
            GlobalImport W.Types.(GlobalType (t, W.Types.Immutable)))
        }))
    | _ ->
        None
  ) decls in

  (* Side-effect: the table is now filled with all the string constants that
   * need to be laid out in the data segment. Compute said data segment. *)
  let data =
    let size = !(env.data_size) in
    let buf = Bytes.create size in
    Hashtbl.iter (fun s rel_addr ->
      let l = String.length s in
      String.blit s 0 buf rel_addr l;
      Bytes.set buf (rel_addr + l) '\000';
    ) env.strings;
    KPrint.bprintf "Wrote out a data segment of size %d\n" size;
    [ dummy_phrase W.Ast.({
        index = mk_var 0;
        offset = dummy_phrase [ dummy_phrase (
          W.Ast.GetGlobal (mk_var (find_global env "data_start"))) ];
        init = Bytes.to_string buf })]
  in

  (* We also to export how big is our data segment so that the next module knows
   * where to start laying out its own static data in the globally-shared
   * memory. *)
  let data_size_index = n_imported_globals + List.length globals in
  let globals = globals @ [ dummy_phrase W.Ast.({
    gtype = W.Types.GlobalType (mk_type I32, W.Types.Immutable);
    value = dummy_phrase (mk_const (mk_int32 (Int32.of_int !(env.data_size))))
  })] in

  (* Export all of the current module's functions & globals. *)
  let exports = KList.filter_map (function
    | Function { public; name; _ } when public ->
        Some (dummy_phrase W.Ast.({
          name;
          ekind = dummy_phrase W.Ast.FuncExport;
          item = mk_var (find_func env name)
        }))
    | Global (name, _, _, public) when public ->
        Some (dummy_phrase W.Ast.({
          name;
          ekind = dummy_phrase W.Ast.GlobalExport;
          item = mk_var (find_global env name)
        }))
    | _ ->
        None
  ) decls @ [
    dummy_phrase W.Ast.({
      name = "data_size";
      ekind = dummy_phrase W.Ast.GlobalExport;
      item = mk_var data_size_index
    })]
  in

  let module_ = dummy_phrase W.Ast.({
    empty_module with
    funcs;
    types;
    globals;
    exports;
    imports;
    data
  }) in
  types, imports_me_included, (name, module_)


(* Since the modules are already topologically sorted, we make each module
 * import all the exports from all the previous modules. [imports] is a list of
 * everything that been made visible so far... ideally, we should only import
 * things that we need. *)
let mk_files files =
  let _, _, modules = List.fold_left (fun (types, imports, modules) file ->
    let types, imports, module_ = mk_module types imports file in
    types, imports, module_ :: modules
  ) (Base.types, Base.imports, []) files in
  List.rev modules
