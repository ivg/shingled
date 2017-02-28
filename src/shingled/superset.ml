open Core_kernel.Std
open Regular.Std
open Bap.Std
open Or_error.Monad_infix
module Dis = Disasm_expert.Basic

open Dis
type maybe_insn = (mem * (Dis.asm, Dis.kinds) Dis.insn option)
type maybe_full_insn = (mem * Dis.full_insn option)
type t = maybe_insn list
type t_full = maybe_full_insn list

let prev_chunk mem ~addr =
  let prev_addr = Addr.pred addr in
  Memory.view ~from:prev_addr mem

let run dis ~accu ~f mem =
  let rec disasm accu cur_mem =
    let elem = match Dis.insn_of_mem dis cur_mem with
      | Ok (m, insn, _) -> m, insn
      | Error _ -> cur_mem, None in
    match prev_chunk mem ~addr:(Memory.min_addr cur_mem) with
    | Ok next -> disasm (f elem accu) next
    | Error _ -> (f elem accu) in
  match Memory.view mem ~from:(Memory.max_addr mem) with
  | Ok cur_mem -> Ok (disasm accu cur_mem)
  | Error err -> Error err

let disasm ?(backend="llvm") ~accu ~f arch mem =
  with_disasm ~backend (Arch.to_string arch) ~f:(fun d -> run d ~accu ~f mem)

let lift lift_fn (mem,insn) =
  match insn with
  | None -> None
  | Some insn ->
    match lift_fn mem insn with
    | Ok bil -> Some (mem, bil)
    | Error _ -> None

let lift arch insns =
  let module Target = (val target_of_arch arch) in
  let lifter = Target.lift in
  let lifted_superset = Addr.Map.empty in
  List.fold insns ~init:lifted_superset
    ~f:(fun lifted_superset (mem, insn) -> 
        match lift lifter (mem, insn) with
        | Some (mem, bil) -> 
          Map.add lifted_superset ~key:(Memory.min_addr mem)
            ~data:(bil, Memory.length mem)
        | None -> lifted_superset
      )

module With_exn = struct
  let disasm ?backend ~accu ~f arch mem = 
    disasm ?backend ~accu ~f arch mem |> ok_exn
end

let memmap_all ?backend arch mem =
  let filter_add = fun elem memmap -> 
    let (mem, insn) = elem in 
    match insn with 
    | Some insn -> Memmap.add memmap mem insn
    | None -> memmap in
  With_exn.disasm ?backend ~accu:Memmap.empty ~f:filter_add arch mem

(* component returns the set of jump points and destinations *)
type indirections = (addr * edge) list Addr.Table.t
let all_indirections brancher shingles =
  let dests = Addr.Table.create () in
  List.iter shingles ~f:(function
      | _,None -> ()
      | mem,Some insn ->
        Brancher.resolve brancher mem insn |> List.iter ~f:(function
            | None,_ -> ()
            | Some addr,kind ->
              Hashtbl.add_multi dests ~key:(Memory.min_addr mem)
                ~data:(addr,kind)));
  dests

type barriers = addr Hash_set.t
let barriers_of_dests dests =
  let barriers = Addr.Hash_set.create () in
  let mark_barrier = Hash_set.add barriers in
  Hashtbl.iteri dests ~f:(fun ~key:src ~data:dsts -> match dsts with
      | _ :: _ :: _ ->
        List.iter dsts ~f:(fun (addr,_) -> mark_barrier addr)
      | _ -> ());
  barriers