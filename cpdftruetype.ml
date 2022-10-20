(* Truetype font parsing and subsetting *)
open Pdfutil
open Pdfio

let fontpack_experiment = true

type t =
  {flags : int;
   minx : int;
   miny : int;
   maxx : int;
   maxy : int;
   italicangle : int;
   ascent : int;
   descent : int;
   capheight : int;
   stemv : int;
   xheight : int;
   avgwidth : int;
   maxwidth : int;
   firstchar : int;
   lastchar : int;
   widths : int array;
   subset_fontfile : Pdfio.bytes;
   subset : int list;
   tounicode : (int, string) Hashtbl.t option}

let dbg = ref false

let required_tables =
  ["head"; "hhea"; "loca"; "cmap"; "maxp"; "cvt "; "glyf"; "prep"; "hmtx"; "fpgm"]

(* 32-bit signed fixed-point number (16.16) returned as two ints *)
let read_fixed b =
  let a = getval_31 b 16 in
    let b = getval_31 b 16 in
      a, b

(* 16-bit unsigned integer *)
let read_ushort b = getval_31 b 16

(* 32-bit unsigned integer *)
let read_ulong b = getval_32 b 32

(* Signed byte *)
let read_byte b = getval_31 b 8

(* Signed short *)
let read_short b = sign_extend 16 (getval_31 b 16)

(* f2dot14 - 2 bit signed integer part, 14 bit unsigned fraction *)
let read_f2dot14 b =
  let v = read_ushort b in
    float_of_int (sign_extend 2 (v lsr 14)) +. (float_of_int (v land 0x3FFF) /. 16384.)

(* discard n bytes *)
let discard_bytes b n =
  for x = 1 to n do ignore (getval_31 b 8) done

let pdf_unit unitsPerEm x =
  int_of_float (float_of_int x *. 1000. /. float_of_int unitsPerEm +. 0.5)

let string_of_tag t =
  Printf.sprintf "%c%c%c%c"
    (char_of_int (i32toi (Int32.shift_right t 24)))
    (char_of_int (i32toi (Int32.logand 0x000000FFl (Int32.shift_right t 16))))
    (char_of_int (i32toi (Int32.logand 0x000000FFl (Int32.shift_right t 8))))
    (char_of_int (i32toi (Int32.logand 0x000000FFl t)))

let read_format_6_encoding_table b =
  let firstCode = read_ushort b in
  let entryCount = read_ushort b in
  let t = null_hash () in
    try
      for x = firstCode to firstCode + entryCount - 1 do
        Hashtbl.add t x (read_ushort b)
      done;
      t
    with
      e -> failwith ("bad format 6 table: " ^ Printexc.to_string e ^ "\n")

(* fixme might need indexToLocFormat here, to undo the "clever" formula. *)
let read_format_4_encoding_table b =
  let t = null_hash () in
  let segCountX2 = read_ushort b in
  let segCount = segCountX2 / 2 in
  let searchRange = read_ushort b in
  let entrySelector = read_ushort b in
  let rangeShift = read_ushort b in
  let endCodes = Array.init segCount (fun _ -> read_ushort b) in
  let _ (* reservedPad *) = read_ushort b in
  let startCodes = Array.init segCount (fun _ -> read_ushort b) in
  let idDelta = Array.init segCount (fun _ -> read_ushort b) in
  let idRangeOffset = Array.init segCount (fun _ -> read_ushort b) in
    if !dbg then
    begin
    Printf.printf "segCount = %i, searchRange = %i, entrySelector = %i, rangeShift = %i\n" segCount searchRange entrySelector rangeShift;
    Printf.printf "endCodes\n";
    print_ints (Array.to_list endCodes);
    Printf.printf "startCodes\n";
    print_ints (Array.to_list startCodes);
    Printf.printf "idDelta\n";
    print_ints (Array.to_list idDelta);
    Printf.printf "idRangeOffset\n";
    print_ints (Array.to_list idRangeOffset);
    end;
    for seg = 0 to segCount - 1 do
      let ec = endCodes.(seg) in
      let sc = startCodes.(seg) in
      let del = idDelta.(seg) in
      let ro = idRangeOffset.(seg) in
        for c = sc to ec do
          if ro = 0 then
            Hashtbl.add t c ((c + del) mod 65536)
          else
            let sum = (c - sc) + del in
              ()
        done
    done;
    t

let print_encoding_table (table : (int, int) Hashtbl.t) =
  let l = list_of_hashtbl table in
  Printf.printf "There are %i characters in this font\n" (length l);
  iter
    (fun (c, gi) -> Printf.printf "Char %04X is at glyph index %i\n" c gi)
    l

let read_encoding_table fmt length version b =
  match fmt with
  | 0 ->
      (*Printf.printf "read_encoding_table: format 0\n";*)
      let t = null_hash () in
        for x = 0 to 255 do Hashtbl.add t x (read_byte b) done;
        t
  | 4 ->
      (*Printf.printf "read_encoding_table: format 4\n";*)
      read_format_4_encoding_table b
  | 6 ->
      (*Printf.printf "read_encoding_table: format 6\n";*)
      read_format_6_encoding_table b
  | n -> raise (Pdf.PDFError "read_encoding_table: format %i not known\n%!")

let read_loca_table indexToLocFormat numGlyphs b =
  match indexToLocFormat with
  | 0 -> Array.init (numGlyphs + 1) (function _ -> i32ofi (read_ushort b * 2))
  | 1 -> Array.init (numGlyphs + 1) (function _ -> read_ulong b)
  | _ -> raise (Pdf.PDFError "Unknown indexToLocFormat in read_loca_table")

let write_loca_table subset cmap indexToLocFormat bs loca =
  let locnums = null_hash () in
    Hashtbl.add locnums 0 (); (* .notdef *)
    iter
      (fun u ->
         let locnum = Hashtbl.find cmap u in
           if !dbg then Printf.printf "write_loca_table: Unicode %i is at location number %i\n" u locnum;
           Hashtbl.add locnums locnum ())
      subset;
  let write_entry loc position =
    match indexToLocFormat with
    | 0 -> putval bs 16 (i32div position 2l)
    | 1 -> putval bs 32 position
    | _ -> raise (Pdf.PDFError "Unknown indexToLocFormat in write_loca_table")
  in
  let pos = ref 0l in
  let pairs =
    map
      (fun loc ->
         let len = i32sub loca.(loc + 1) loca.(loc) in
         let r = (loc, !pos) in
           pos := i32add !pos len;
           r)
      (sort compare (map fst (list_of_hashtbl locnums)))
  in
    let pairs = Array.of_list (pairs @ [(Array.length loca - 1, !pos)]) in
    Array.iteri
      (fun i (loc, off) ->
         if i <> Array.length pairs - 1 then
           begin
             write_entry loc off;
             let loc', off' = pairs.(i + 1) in
             for x = 0 to loc' - loc - 2 do write_entry (loc + x) off' done
           end
         else
           write_entry loc off)
      pairs

(* Write the notdef glyf, and any others in the subset *)
let write_glyf_table subset cmap bs mk_b glyfoffset loca =
  if !dbg then Printf.printf "***write_glyf_table\n";
  let locnums = null_hash () in
    Hashtbl.add locnums 0 (); (* .notdef *)
    iter
      (fun u ->
         let locnum = Hashtbl.find cmap u in
         if !dbg then Printf.printf "write_glyf_table: Unicode %i is at location number %i\n" u locnum;
           Hashtbl.add locnums locnum ())
      subset;
  let locnums = sort compare (map fst (list_of_hashtbl locnums)) in
  if !dbg then (Printf.printf "We want glyfs for locations: "; iter (Printf.printf "%i ") locnums; Printf.printf "\n");
    let byteranges = map (fun x -> (loca.(x), loca.(x + 1))) locnums in
    if !dbg then (Printf.printf "Byte ranges: "; iter (fun (a, b) -> Printf.printf "(%li, %li) " a b) byteranges; Printf.printf "\n");
  let len = List.fold_left i32add 0l (map (fun (a, b) -> i32sub b a) byteranges) in
  let write_bytes bs a l =
    if !dbg then Printf.printf "glyf: write_bytes %li %li\n" a l;
    let b = mk_b (i32toi (i32add glyfoffset a)) in
      for x = 1 to i32toi l do putval bs 8 (getval_32 b 8) done
  in
    iter (fun (a, b) -> write_bytes bs a (i32sub b a)) byteranges;
    let padding = 4 - i32toi len mod 4 in
    for x = 1 to padding do putval bs 8 0l done;
    len

let read_os2_table unitsPerEm b blength =
  let version = read_ushort b in
  if !dbg then Printf.printf "OS/2 table blength = %i bytes, version number = %i\n" blength version;
  let xAvgCharWidth = pdf_unit unitsPerEm (read_short b) in
  discard_bytes b 64; (* discard 14 entries usWeightClass...fsLastCharIndex *)
  (* -- end of original OS/2 Version 0 Truetype table. Must check length before reading now. *)
  let sTypoAscender = if blength > 68 then pdf_unit unitsPerEm (read_short b) else 0 in
  let sTypoDescender = if blength > 68 then pdf_unit unitsPerEm (read_short b) else 0 in
  discard_bytes b 6; (* discard sTypoLineGap...usWinDescent *)
  (* -- end of OpenType version 0 table *)
  discard_bytes b 8; (* discard ulCodePageRange1, ulCodePageRange2 *)
  (* -- end of OpenType version 1 table *)
  let sxHeight = if version < 2 then 0 else pdf_unit unitsPerEm (read_short b) in
  let sCapHeight = if version < 2 then 0 else pdf_unit unitsPerEm (read_short b) in
    (sTypoAscender, sTypoDescender, sCapHeight, sxHeight, xAvgCharWidth)

let read_post_table b =
  discard_bytes b 4; (* discard version *)
  let italicangle, n = read_fixed b in
    italicangle

(* Eventually:
Set bit 6 for non symbolic. (nb bit 1 is actualy bit 0 etc.)
Set bit 7 if italicangle <> 0
Set bit 2 if serif ?
Set bit 1 if fixed pitch (calculate from widths) *)
let calculate_flags italicangle =
  let italic = if italicangle <> 0 then 1 else 0 in 
    32 lor italic lsl 6

let calculate_limits subset =
  if subset = [] then (0, 255) else
    extremes (sort compare subset)

let calculate_stemv () = 0

let read_hhea_table b =
  discard_bytes b 34;
  read_ushort b (* numOfLongHorMetrics *)

let read_hmtx_table numOfLongHorMetrics b =
  Array.init
    numOfLongHorMetrics
    (fun _ -> let r = read_ushort b in ignore (read_short b); r)

(* For widths, we need the unicode code, not the unencoded byte *)
let unicode_codepoint_of_pdfcode encoding_table glyphlist_table p =
  try
    hd (Hashtbl.find glyphlist_table (Hashtbl.find encoding_table p))
  with
    Not_found -> 0

let calculate_widths unitsPerEm encoding firstchar lastchar subset cmapdata hmtxdata =
  if lastchar < firstchar then failwith "lastchar < firstchar" else
  (*if !dbg then List.iter (fun (a, b) -> Printf.printf "%i -> %i\n" a b) (sort compare (list_of_hashtbl cmapdata));*)
  let encoding_table = Pdftext.table_of_encoding encoding in
  let glyphlist_table = Pdfglyphlist.glyph_hashes () in
  Array.init
    (lastchar - firstchar + 1)
    (fun pos ->
       let code = pos + firstchar in
       (*if !dbg then Printf.printf "code %i --> " code;*)
       let code = unicode_codepoint_of_pdfcode encoding_table glyphlist_table code in
       (*if !dbg then Printf.printf "unicode %i --> " code;*)
       if subset <> [] && not (mem code subset) then 0 else
       try
         let glyphnum = Hashtbl.find cmapdata code in
         (*if !dbg then Printf.printf "glyph number %i --> " glyphnum;*)
           let width = hmtxdata.(glyphnum) in
           (*if !dbg then Printf.printf "width %i\n" width;*)
             pdf_unit unitsPerEm width
       with e -> if !dbg then Printf.printf "no width for %i\n" code; 0)

let calculate_maxwidth unitsPerEm hmtxdata =
  pdf_unit unitsPerEm (hd (sort (fun a b -> compare b a) (Array.to_list hmtxdata)))

let padword n =
  let n = i32toi n in
  let r = n + (if n mod 4 = 0 then 0 else 4 - n mod 4) in
    i32ofi r

let subset_font major minor tables indexToLocFormat subset encoding cmap loca mk_b glyfoffset data =
  let tables = Array.of_list (sort (fun (_, _, o, _) (_, _, o', _) -> compare o o') tables) in
  let tablesout = ref [] in
  let cut = ref 0l in
  if !dbg then Printf.printf "***Input:\n";
  Array.iteri
    (fun i (tag, checkSum, offset, ttlength) ->
      if !dbg then Printf.printf "tag = %li = %s, offset = %li\n" tag (string_of_tag tag) offset;
      if mem (string_of_tag tag) required_tables then
         tablesout := (tag, checkSum, i32sub offset !cut, ttlength)::!tablesout
      else
        cut := i32add !cut (match tables.(i + 1) with (_, _, offset', _) -> i32sub offset' offset))
    tables;
  (* Reduce offsets by the reduction in header table size *)
  let header_size_reduction = i32ofi (16 * (Array.length tables - length !tablesout)) in
  let glyf_table_size_reduction = ref 0l in
  let newtables =
    Array.of_list
      (map
        (fun (tag, checksum, offset, ttlength) ->
          let ttlength =
            if string_of_tag tag = "glyf" && subset <> [] then
              let bs = make_write_bitstream () in
                let newlen = write_glyf_table subset cmap bs mk_b glyfoffset loca in
                let paddedlen = i32ofi (bytes_size (bytes_of_write_bitstream bs)) in
                  if !dbg then Printf.printf "new glyf table length = %li\n" newlen;
                  glyf_table_size_reduction := i32sub (padword ttlength) paddedlen;
                  newlen
            else ttlength
          in
            let offset' =
              i32sub
                (i32sub offset header_size_reduction)
                (if string_of_tag tag = "glyf" then 0l else !glyf_table_size_reduction)
            in
              (tag, checksum, offset', ttlength))
        (rev !tablesout))
  in
  if !dbg then Printf.printf "***Reduced:\n";
  Array.iter
    (fun (tag, checkSum, offset, ttlength) -> 
      if !dbg then Printf.printf "tag = %li = %s, offset = %li, length = %li\n" tag (string_of_tag tag) offset ttlength)
    newtables;
  let bs = make_write_bitstream () in
  (* table directory *)
  let numtables = Array.length newtables in
  putval bs 16 (i32ofi major);
  putval bs 16 (i32ofi minor);
  putval bs 16 (i32ofi numtables); (* numTables *)
  putval bs 16 (i32ofi (16 * pow2lt numtables)); (* searchRange *)
  putval bs 16 (i32ofi (int_of_float (log (float_of_int (pow2lt numtables))))); (* entrySelector *)
  putval bs 16 (i32ofi (numtables * 16)); (* rangeShift *)
  Array.iter
    (fun (tag, checkSum, offset, ttlength) ->
      putval bs 32 tag;
      putval bs 32 checkSum;
      putval bs 32 offset;
      putval bs 32 ttlength)
    newtables;
  (* find each table in original data, calculating the length from the next offset.
     On the last, copy until we run out of data *)
  let findtag tag =
    let off = ref 0l in
    let len = ref None in
    begin try
      for x = 0 to Array.length tables - 1 do
        let t, _, offset, _ = tables.(x) in
          if t = tag then
            begin
              off := offset; 
              if x < Array.length tables - 1 then
                len := Some (let _, _, nextoffset, _ = tables.(x + 1) in i32sub nextoffset offset);
              raise Exit
            end
      done;
      failwith "failed to find table"
    with
      Exit -> (!off, !len)
    end
  in
  Array.iter
    (fun (tag, _, _, _) ->
      if !dbg then Printf.printf "Writing %s table\n" (string_of_tag tag);
      if string_of_tag tag = "loca" && subset <> [] then
        write_loca_table subset cmap indexToLocFormat bs loca
      else if string_of_tag tag = "glyf" && subset <> [] then
        ignore (write_glyf_table subset cmap bs mk_b glyfoffset loca)
      else
        match findtag tag with
        | (og_off, Some len) ->
            let b = mk_b (i32toi og_off) in
              for x = 0 to i32toi len - 1 do putval bs 8 (getval_32 b 8) done
        | (og_off, None) ->
            let b = mk_b (i32toi og_off) in
              try
                while true do putval bs 8 (getval_32 b 8) done
              with
                _ -> ())
    newtables;
  let bytes = bytes_of_write_bitstream bs in
    if !dbg then Printf.printf "Made subset font of length %i bytes\n" (bytes_size bytes);
    let o = open_out_bin "fontout.ttf" in
      output_string o (string_of_bytes bytes);
      close_out o;
    bytes

let parse ?(subset=[]) data encoding =
  let mk_b byte_offset = bitbytes_of_input (let i = input_of_bytes data in i.seek_in byte_offset; i) in
  let b = mk_b 0 in
  let major, minor = read_fixed b in
    if !dbg then Printf.printf "Truetype font version %i.%i\n" major minor;
    let numTables = read_ushort b in
    let searchRange = read_ushort b in
    let entrySelector = read_ushort b in
    let rangeShift = read_ushort b in
      if !dbg then Printf.printf "numTables = %i, searchRange = %i, entrySelector = %i, rangeShift = %i\n"
        numTables searchRange entrySelector rangeShift;
      let tables = ref [] in
        for x = 1 to numTables do
          let tag = read_ulong b in
          let checkSum = read_ulong b in
          let offset = read_ulong b in
          let ttlength = read_ulong b in
            if !dbg then Printf.printf "tag = %li = %s, checkSum = %li, offset = %li, ttlength = %li\n"
            tag (string_of_tag tag) checkSum offset ttlength;
            tables =| (tag, checkSum, offset, ttlength);
        done;
          let headoffset, headlength =
            match keep (function (t, _, _, _) -> string_of_tag t = "head") !tables with
            | (_, _, o, l)::_ -> o, l
            | [] -> raise (Pdf.PDFError "No maxp table found in TrueType font")
          in
            let b = mk_b (i32toi headoffset) in
              discard_bytes b 18;
              let unitsPerEm = read_ushort b in
              discard_bytes b 16;
              let minx = pdf_unit unitsPerEm (read_short b) in
              let miny = pdf_unit unitsPerEm (read_short b) in
              let maxx = pdf_unit unitsPerEm (read_short b) in
              let maxy = pdf_unit unitsPerEm (read_short b) in
              discard_bytes b 6;
              let indexToLocFormat = read_short b in
              let _ (*glyphDataFormat*) = read_short b in
                if !dbg then Printf.printf "head table: indexToLocFormat is %i\n" indexToLocFormat;
                if !dbg then Printf.printf "box %i %i %i %i\n" minx miny maxx maxy;
        let os2 =
          match keep (function (t, _, _, _) -> string_of_tag t = "OS/2") !tables with
          | (_, _, o, l)::_ -> Some (o, l)
          | [] -> None
        in
        let ascent, descent, capheight, xheight, avgwidth =
          match os2 with
          | None -> raise (Pdf.PDFError "No os/2 table found in truetype font")
          | Some (o, l) -> let b = mk_b (i32toi o) in read_os2_table unitsPerEm b (i32toi l)
        in
        let italicangle =
          match keep (function (t, _, _, _) -> string_of_tag t = "post") !tables with
          | (_, _, o, _)::_ -> read_post_table (mk_b (i32toi o))
          | _ -> 0
        in
        if !dbg then
          Printf.printf "ascent %i descent %i capheight %i xheight %i avgwidth %i\n"
            ascent descent capheight xheight avgwidth;
        let cmap =
          match keep (function (t, _, _, _) -> string_of_tag t = "cmap") !tables with
          | (_, _, o, l)::_ -> Some (o, l)
          | [] -> None
        in
        let glyphcodes = ref (null_hash ()) in
          begin match cmap with
          | None ->
              for x = 0 to 255 do Hashtbl.add !glyphcodes x x done
          | Some (cmapoffset, cmaplength) -> 
              let b = mk_b (i32toi cmapoffset) in
                let cmap_version = read_ushort b in
                let num_encoding_tables = read_ushort b in
                  if !dbg then Printf.printf "cmap version %i. There are %i encoding tables\n"
                    cmap_version num_encoding_tables;
                  for x = 1 to num_encoding_tables do
                    let platform_id = read_ushort b in
                    let encoding_id = read_ushort b in
                    let subtable_offset = read_ulong b in
                      if !dbg then Printf.printf "subtable %i. platform_id = %i, encoding_id = %i, subtable_offset = %li\n"
                        x platform_id encoding_id subtable_offset;
                      let b = mk_b (i32toi cmapoffset + i32toi subtable_offset) in
                        let fmt = read_ushort b in
                        let lngth = read_ushort b in
                        let version = read_ushort b in
                          if !dbg then Printf.printf "subtable has format %i, length %i, version %i\n" fmt lngth version;
                          let got_glyphcodes = read_encoding_table fmt length version b in
                            (*print_encoding_table got_glyphcodes; *)
                            Hashtbl.iter (Hashtbl.add !glyphcodes) got_glyphcodes;
                            (*Printf.printf "Retrieved %i cmap entries in total\n" (length (list_of_hashtbl !glyphcodes))*)
                  done;
          end;
          let maxpoffset, maxplength =
            match keep (function (t, _, _, _) -> string_of_tag t = "maxp") !tables with
            | (_, _, o, l)::_ -> o, l
            | [] -> raise (Pdf.PDFError "No maxp table found in TrueType font")
          in
          let b = mk_b (i32toi maxpoffset) in
            let mmajor, mminor = read_fixed b in
            let numGlyphs = read_ushort b in
              if !dbg then Printf.printf "maxp table version %i.%i: This font has %i glyphs\n" mmajor mminor numGlyphs;
          let locaoffset, localength =
            match keep (function (t, _, _, _) -> string_of_tag t = "loca") !tables with
            | (_, _, o, l)::_ -> o, l
            | [] -> raise (Pdf.PDFError "No loca table found in TrueType font")
          in
            let subset_1 = if subset = [] then [] else if fontpack_experiment then tl subset else subset in
            let subset_2 = if subset = [] then [] else [hd subset] in
            let flags = calculate_flags italicangle in
            let firstchar_1, lastchar_1 = calculate_limits subset_1 in
            let firstchar_2, lastchar_2 = calculate_limits subset_2 in
            let numOfLongHorMetrics =
              match keep (function (t, _, _, _) -> string_of_tag t = "hhea") !tables with
              | (_, _, o, l)::_ -> let b = mk_b (i32toi o) in read_hhea_table b
              | _ -> 0
            in
            let hmtxdata =
              match keep (function (t, _, _, _) -> string_of_tag t = "hmtx") !tables with
              | (_, _, o, _)::_ -> read_hmtx_table numOfLongHorMetrics (mk_b (i32toi o))
              | [] -> raise (Pdf.PDFError "No hmtx table found in TrueType font")
            in
            let widths_1 = calculate_widths unitsPerEm encoding firstchar_1 lastchar_1 subset_1 !glyphcodes hmtxdata in
            let widths_2 = calculate_widths unitsPerEm encoding firstchar_2 lastchar_2 subset_2 !glyphcodes hmtxdata in
            let maxwidth = calculate_maxwidth unitsPerEm hmtxdata in
            let stemv = calculate_stemv () in
            let b = mk_b (i32toi locaoffset) in
            let loca = read_loca_table indexToLocFormat numGlyphs b in
            let glyfoffset, glyflength =
              match keep (function (t, _, _, _) -> string_of_tag t = "glyf") !tables with
              | (_, _, o, l)::_ -> o, l
              | [] -> raise (Pdf.PDFError "No glyf table found in TrueType font")
            in
            let main_subset =
              subset_font major minor !tables indexToLocFormat subset_1
              encoding !glyphcodes loca mk_b glyfoffset data
            in
            let second_subset =
              subset_font major minor !tables indexToLocFormat subset_2
              encoding !glyphcodes loca mk_b glyfoffset data
            in
              let second_tounicode =
                if subset = [] then None else
                  let h = null_hash () in
                  let s = (implode (tl (tl (explode (Pdftext.utf16be_of_codepoints [hd subset]))))) in
                    Printf.printf "String for tounicode = %S\n" s;
                    Hashtbl.add h 0 s;
                    Some h
              in
              [{flags; minx; miny; maxx; maxy; italicangle; ascent; descent;
                capheight; stemv; xheight; avgwidth; maxwidth; firstchar = firstchar_1; lastchar = lastchar_1;
                widths = widths_1; subset_fontfile = main_subset; subset = subset_1; tounicode = None}]
              @ if fontpack_experiment then
               [{flags; minx; miny; maxx; maxy; italicangle; ascent; descent;
                capheight; stemv; xheight; avgwidth; maxwidth; firstchar = firstchar_2; lastchar = lastchar_2;
                widths = widths_2; subset_fontfile = second_subset; subset = subset_2;
                tounicode = second_tounicode}] else []
