(* Create a DLL from a set of "closed" COFF files (no imported symbol). *)

open Coff

let (&&&) = Int32.logand
let (|||) = Int32.logor
let (<<<) = Int32.shift_left

let read_int32 s i =
  Int32.of_int (Char.code s.[i]) |||
  (Int32.of_int (Char.code s.[i+1]) <<< 8) |||
  (Int32.of_int (Char.code s.[i+2]) <<< 16) |||
  (Int32.of_int (Char.code s.[i+3]) <<< 24)

let int32_to_buf b i =
  for k = 0 to 3 do
    Buffer.add_char b (Char.chr (Int32.to_int (Int32.shift_right i (k * 8)) land 0xff))
  done

let align x n =
  let k = Int32.rem x n in
  if k = 0l then x
  else Int32.add x (Int32.sub n k)

let discard_section s =
  let opts = s.sec_opts in
  opts &&&
  (0x00000200l (* Info section (.drectve) *)
 ||| 0x00000800l (* Remove *)
 ||| 0x02000000l) <> 0l (* Discardable *)

let sect_data s =
  match force_section_data s with
  | `String data -> data
  | _ -> assert false

let split_relocs page_size relocs =
  let relocs = List.sort compare relocs in
  let blocks = ref [] and current_block = ref (ref []) and current_base = ref (-1l) in
  List.iter
    (fun rva ->
      let base = Int32.mul (Int32.div rva page_size) page_size in
      let ofs = Int32.to_int (Int32.sub rva base) in
      if base = !current_base then (!current_block) := ofs :: !(!current_block)
      else begin
        current_base := base;
        current_block := ref [ofs];
        blocks := (base, !current_block) :: !blocks
      end
    )
    relocs;
  List.rev_map (fun (base, relocs) -> (base, List.rev !relocs)) !blocks


type sec_info = {
    sec_info_obj: coff; (* original object *)
    mutable sec_info_sec: section; (* target section in the image *)
    mutable sec_info_ofs: int32; (* offset within the target image *)
  }

let create_dll oc objs =
  let image_base = 0x10000000l in
  let page_size = 0x1000l in
  let dllname = "foo.dll" in

  (* msdos stub *)
  output_string oc "MZ";
  for i = 3 to 0x3c do output_byte oc 0 done;
  emit_int32 oc 0xe8l; (* file offset of COFF file header, just here *)
  for i = 0x40 to 0xe7 do output_byte oc 0 done;

  let sections = Hashtbl.create 8 in
  let sec_id = ref 0 in
  let sec_info = Hashtbl.create 8 in
  let sym_id = ref 0 in
  let globals = Hashtbl.create 8 in
  let locals = Hashtbl.create 8 in
  let relocs = ref [] in
  List.iter
    (fun obj ->
      List.iter
        (fun s ->
          (* todo: cut the section name at 8 chars, remove the part of $ *)
          if discard_section s then ()
          else let (l, sect) =
            try Hashtbl.find sections s.sec_name
            with Not_found ->
              let r =
                ref [],
                Section.create s.sec_name
                  (s.sec_opts
                     &&& (0x00000020l
                        ||| 0x00000040l
                        ||| 0x00000080l
                        ||| 0x10000000l
                        ||| 0x20000000l
                        ||| 0x40000000l
                        ||| 0x80000000l))
              in
              Hashtbl.replace sections s.sec_name r;
              r
          in
          l := s :: !l;
          s.sec_pos <- !sec_id;
          incr sec_id;
          Hashtbl.replace sec_info s.sec_pos
            {
             sec_info_obj = obj;
             sec_info_sec = sect;
             sec_info_ofs = 0l;
           }
        )
        obj.sections;

      List.iter
        (function
          | {sym_name=name; value=ofs; storage=storage; section = `Section s} as sym when s.sec_pos >= 0 ->
              let info = Hashtbl.find sec_info s.sec_pos in
              let rva =
                Future.create_delayed
                  (fun () ->
                    Int32.add ofs
                      (
                       Int32.add
                         info.sec_info_ofs
                         info.sec_info_sec.vaddress
                      )
                  )
              in
              if storage = 2
              then Hashtbl.replace globals name rva
              else begin
                sym.sym_pos <- !sym_id;
                incr sym_id;
                Hashtbl.replace locals sym.sym_pos rva
              end
          | _ ->
              ()
        )
        obj.symbols;
    )
    objs;

  let rva_of_global s =
    try Hashtbl.find globals s
    with Not_found -> failwith ("Cannot find global symbol " ^ s)
  in
  let rva_of_local s =
    try Hashtbl.find locals s
    with Not_found -> assert false
  in

  let sects = ref [] in
  (* Put image sections at their target rva *)
  let va = ref 0x1000l in
  let put_sect s =
    s.vsize <- Int32.of_int (Section.size s);
    s.vaddress <- !va;
    va := align (Int32.add !va s.vsize) 0x1000l;
    sects := s :: !sects
  in

  Hashtbl.iter
    (fun name (l, sect) ->
      let data = Buf.create () in
      List.iter
        (fun s ->
          let info = Hashtbl.find sec_info s.sec_pos in
          let sec_ofs = Buf.length data in
          info.sec_info_ofs <- Int32.of_int sec_ofs;
          let sdata = sect_data s in
          Buf.string data sdata;
          List.iter
            (fun r ->
              (* rva of the target symbol *)
              let sym = r.symbol in
              let rva =
                if Symbol.is_extern sym || Symbol.is_export sym then rva_of_global sym.sym_name
                else if sym.sym_pos >= 0 then rva_of_local sym.sym_pos
                else begin
                  Symbol.dump sym;
                  failwith (Printf.sprintf "Cannot resolve symbol %s\n" sym.sym_name)
                end
              in

              (* rva of the relocation *)
              let rel_rva =
                Future.create_delayed
                  (fun () ->
                    Int32.add r.addr
                      (Int32.add
                         info.sec_info_sec.vaddress
                         info.sec_info_ofs
                      ))
              in

              let initial = read_int32 sdata (Int32.to_int r.addr) in
              let initial = Future.create_cst initial in
              Buf.at data (sec_ofs + Int32.to_int r.addr)
                (fun () ->
                  match r.rtype with
                  | 0x06 -> (* absolute address *)
                      relocs := rel_rva :: !relocs;
                      let rva = Future.add rva (Future.create_cst image_base) in
                      Buf.lazy_int32 data (Future.get (Future.add initial rva))
                  | 0x14 -> (* rel32 *)
                      let rva = Future.sub rva (Future.create_cst 4l) in
                      Buf.lazy_int32 data (Future.get (Future.sub (Future.add initial rva) rel_rva))
                  | _ ->
                      assert false
                )
            )
            s.relocs
        )
        !l;
      sect.data <- `Buf data;
      put_sect sect
    )
    sections;

  (* create the export table *)
  let edata =
    let edata = Section.create ".edata" 0x40000040l in
    let b = Buf.create () in
    edata.data <- `Buf b;

    let export_symbols = ["symtbl";"reloctbl"] in
    let export_symbols = List.sort compare export_symbols in
    Buf.int32 b 0l; (* flags *)
    Buf.int32 b 0l; (* timestamp *)
    Buf.int32 b 0l; (* version *)
    let dllname_offset = Buf.future_int32 b in (* name rva *)
    Buf.int32 b 1l; (* ordinal base *)
    Buf.int32 b (Int32.of_int (List.length export_symbols)); (* addr table entries *)
    Buf.int32 b (Int32.of_int (List.length export_symbols)); (* number of name pointers *)
    let exp_tbl = Buf.future_int32 b in (* export address table rva *)
    let name_ptr_tbl = Buf.future_int32 b in (* name pointer rva *)
    let ord_ptr_tbl = Buf.future_int32 b in (* ordinal table pointer rva *)
    Buf.set_future b dllname_offset (fun () -> edata.vaddress);
    Buf.string b dllname;
    Buf.int8 b 0;
    Buf.set_future b exp_tbl (fun () -> edata.vaddress);
    List.iter (fun s -> Buf.lazy_int32 b (Future.get (rva_of_global ("_" ^ s))))
      export_symbols;
    Buf.set_future b name_ptr_tbl (fun () -> edata.vaddress);
    let export_symbols_ofs =
      List.map (fun _ -> Buf.future_int32 b) export_symbols
    in
    Buf.set_future b ord_ptr_tbl (fun () -> edata.vaddress);
    for i = 0 to List.length export_symbols - 1 do
      Buf.int16 b i
    done;
    List.iter2
      (fun s f ->
        Buf.set_future b f (fun () -> edata.vaddress);
        Buf.string b s;
        Buf.int8 b 0
      )
      export_symbols
      export_symbols_ofs;
    put_sect edata;
    edata
  in

  (* create the reloc table *)
  let rdata =
    let rdata = Section.create ".rdata" 0x40000040l in
    let b = Buf.create () in
    rdata.data <- `Buf b;

    (* careful with list functions: the list of relocs can be very long *)
    let relocs = List.rev_map (fun rva -> Future.get rva ()) !relocs in
    let relocs = split_relocs page_size relocs in
    List.iter
      (fun (base, relocs) ->
        let n = List.length relocs in
        let size = 8 + 2 * n in
        let size = if n mod 2 = 1 then size + 2 else size in
        Buf.int32 b base;
        Buf.int32 b (Int32.of_int size);
        List.iter
          (fun ofs -> Buf.int16 b (ofs lor 0x3000)) (* HIGHLOW reloc *)
          relocs;
        if n mod 2 = 1 then Buf.int16 b 0
      )
      relocs;
    put_sect rdata;
    rdata
  in

  output_string oc "PE\000\000";
  (* coff header *)
  emit_int16 oc 0x14c; (* machine: i386 *)
  emit_int16 oc (List.length !sects); (* number of sections *)
  emit_int32 oc 0l; (* date *)
  emit_int32 oc 0l; (* ptr to symbol table *)
  emit_int32 oc 0l; (* number of symbols *)
  emit_int16 oc (28 + 68 + 8 * 16); (* size of optional headers *)
  emit_int16 oc 0x2102; (* flags: exec, 32-bit, dll *)

  (* optional header *)
  (*   standard fields *)
  emit_int16 oc 0x10b; (* magic: pe32 *)
  emit_int16 oc 8; (* linker version *)
  emit_int32 oc 0l; (* size of code *)
  emit_int32 oc 0l; (* size of initialized data *)
  emit_int32 oc 0l; (* size of uninitialized data *)
  emit_int32 oc 0l; (* entry point *)
  emit_int32 oc 0x1000l; (* base of code *)
  emit_int32 oc 0x1000l; (* base of data *)
  (*   windows-specific fields *)
  emit_int32 oc image_base; (* image base *)
  emit_int32 oc 0x1000l; (* section alignment *)
  emit_int32 oc 0x200l; (* file alignment *)
  emit_int32 oc 0x04l; (* OS version *)
  emit_int32 oc 0l; (* image version *)
  emit_int32 oc 0x04l; (* subsystem version *)
  emit_int32 oc 0l; (* win32 version *)
  emit_int32 oc !va; (* size of image *)
  let size_of_headers = pos_out oc in
  emit_int32 oc 0l; (* size of headers *)
  emit_int32 oc 0l; (* checksum *)
  emit_int16 oc 3; (* subsystem: windows CUI *)
  emit_int16 oc 0x400; (* characteristics: no EH *)
  emit_int32 oc 0x100000l; (* size of stack commit *)
  emit_int32 oc 0x1000l; (* size of stack commit *)
  emit_int32 oc 0x100000l; (* size of heap commit *)
  emit_int32 oc 0x1000l; (* size of heap commit *)
  emit_int32 oc 0l; (* loader flags *)
  emit_int32 oc 16l; (* number of directories *)

  (* directories *)
  for i = 0 to 15 do
    match i with
    | 0 -> emit_int32 oc edata.vaddress; emit_int32 oc edata.vsize
    | 5 -> emit_int32 oc rdata.vaddress; emit_int32 oc rdata.vsize
    | _ -> emit_int32 oc 0l; emit_int32 oc 0l;
  done;

  let sects =
    List.map (Section.put (fun _ -> assert false) oc) (List.rev !sects)
  in
  let align_file () =
    let i = pos_out oc mod 0x200 in
    if i <> 0 then for k = i + 1 to 0x200 do output_char oc '\000' done;
  in
  align_file ();
  patch_int32 oc size_of_headers (Int32.of_int (pos_out oc));
  List.iter (fun (data,_) -> align_file (); data ()) sects
