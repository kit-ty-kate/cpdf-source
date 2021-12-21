open Pdfutil
open Cpdferror

(* \section{Add bookmarks} *)
let read_lines input =
  let lines = ref [] in
   try
     while true do
       let c = read_line input in
         lines =| c
    done; []
   with
     _ -> rev !lines

(* Verify a list of bookmarks. Positive jumps of > 1 not allowed, no numbers
smaller than 0. *)
let rec verify_bookmarks pdf lastlevel fastrefnums endpage = function
  | [] -> true
  | {Pdfmarks.level = level; Pdfmarks.target = target}::more ->
      let page = Pdfpage.pagenumber_of_target pdf ~fastrefnums target in
        level < lastlevel + 2 &&
        level >= 0 &&
        page <= endpage &&
        page >= 0 &&
        verify_bookmarks pdf level fastrefnums endpage more

let verify_bookmarks pdf lastlevel endpage marks =
  let refnums = Pdf.page_reference_numbers pdf in
  let fastrefnums = hashtable_of_dictionary (combine refnums (indx refnums)) in
    match marks with
    | [] -> true
    | m::more -> m.Pdfmarks.level = 0 && verify_bookmarks pdf lastlevel fastrefnums endpage more

(* Parse a line of the bookmarks file. *)

(* Un-escape things which are escaped. Quotes, newlines and backslashes *)
let rec fixup_characters prev = function
  | [] -> rev prev
  | '\\'::'\\'::t -> fixup_characters ('\\'::prev) t
  | '\\'::'"'::t -> fixup_characters ('"'::prev) t
  | '\\'::'n'::t -> fixup_characters ('\n'::prev) t
  | h::t -> fixup_characters (h::prev) t

let debug_bookmark_string s =
  Printf.printf "STR: %s\n" s

(* If optionaldest = [Pdfgenlex.LexString s], we parse the string, convert the
 * integer to an indirect of the real page target, and then put it in. *)
let target_of_markfile_obj pdf i' pdfobj =
  (*Printf.printf "Parsed %s\n" (Pdfwrite.string_of_pdf pdfobj);*)
  match pdfobj with
    Pdf.Array (Pdf.Integer x::more) ->
      let pageobjnum = Pdfpage.page_object_number pdf i' in
        begin match pageobjnum with
          None ->
            raise (Pdf.PDFError "bookmark_of_data: page obj num not found")
        | Some p ->
            Pdfdest.read_destination pdf (Pdf.Array (Pdf.Indirect p::more))
        end
  (* Need to deal with "null", "(string)", and "<<other thing like action" *) 
  | Pdf.Null -> Pdfdest.NullDestination
  | Pdf.String s -> Pdfdest.read_destination pdf (Pdf.String s)
  | x -> Pdfdest.Action x

let target_of_markfile_target pdf i' = function
  | [Pdfgenlex.LexString s] ->
      let pdfobj = Pdfread.parse_single_object s in
        target_of_markfile_obj pdf i' pdfobj
  | _ -> Pdfpage.target_of_pagenumber pdf i'

let bookmark_of_data pdf i s i' isopen optionaldest =
    (*debug_bookmark_string s;
    debug_bookmark_string (implode (fixup_characters [] (explode s)));
    debug_bookmark_string (Pdftext.pdfdocstring_of_utf8 (implode (fixup_characters [] (explode s))));*)
    {Pdfmarks.level = i;
     Pdfmarks.text = Pdftext.pdfdocstring_of_utf8 (implode (fixup_characters [] (explode s)));
     Pdfmarks.target = target_of_markfile_target pdf i' optionaldest;
     Pdfmarks.isopen = isopen}

let target_of_json_target pdf pagenumber target = 
  target_of_markfile_obj pdf pagenumber (Cpdfjson.object_of_json target)

let mark_of_json pdf = function
  | `Assoc [("level", `Int level);
            ("text", `String text);
            ("page", `Int pagenumber);
            ("open", `Bool openstatus);
            ("target", target)] ->
       {Pdfmarks.level = level;
        Pdfmarks.text = Pdftext.pdfdocstring_of_utf8 text;
        Pdfmarks.target = target_of_json_target pdf pagenumber target;
        Pdfmarks.isopen = openstatus}
  | _ -> error "malformed mark in mark_of_json"

let marks_of_json pdf = function
  | `List ms -> map (mark_of_json pdf) ms
  | _ -> error "top level of JSON boomark file not a list"

let parse_bookmark_file_json verify pdf i =
  let module J = Cpdfyojson.Safe in
    try
      let json =
        match i.Pdfio.caml_channel with
        | Some ch -> J.from_channel ch
        | None ->
          let content = Pdfio.string_of_bytes (Pdfio.bytes_of_input i 0 i.Pdfio.in_channel_length) in
            J.from_string content
      in
      let marks = marks_of_json pdf json in
        if verify then
          if verify_bookmarks pdf 0 (Pdfpage.endpage pdf) marks then marks else
            error "Bad bookmark file (References non-existant pages or is malformed)"
        else
          marks
    with
      e ->
        error (Printf.sprintf "Malformed JSON bookmark file (%s)" (Printexc.to_string e)) 

let parse_bookmark_file verify pdf input =
  let currline = ref 0 in
  try
    let lines = Pdfio.read_lines input in
      let currline = ref 0 in
      let bookmarks = ref [] in
        iter
          (function line ->
             match
               incr currline;
               Pdfgenlex.lex_string line
             with
             | Pdfgenlex.LexInt i::Pdfgenlex.LexString s::Pdfgenlex.LexInt i'::Pdfgenlex.LexName "open"::optionaldest ->
                 bookmarks =| bookmark_of_data pdf i s i' true optionaldest
             | Pdfgenlex.LexInt i::Pdfgenlex.LexString s::Pdfgenlex.LexInt i'::optionaldest ->
                 bookmarks =| bookmark_of_data pdf i s i' false optionaldest
             | [] -> () (* ignore blank lines *)
             | _ ->
                 error ("Bad bookmark file, line " ^ (string_of_int !currline)))
          lines;
        let bookmarks = rev !bookmarks in
          if verify then
            if verify_bookmarks pdf 0 (Pdfpage.endpage pdf) bookmarks
                then bookmarks
                else
                  error
                    "Bad bookmark file (References non-existant pages or is malformed)"
            else
              bookmarks
  with
    e ->
      error
        (Printf.sprintf 
           "Bad bookmark file (syntax) at line %i (error was %s)"
           !currline
           (Printexc.to_string e))


let add_bookmarks ~json verify input pdf =
  let parsed =
    (if json then parse_bookmark_file_json else parse_bookmark_file) verify pdf input in
    (*iter (fun b -> flprint (Pdfmarks.string_of_bookmark b); flprint "\n") parsed;*)
    Pdfmarks.add_bookmarks parsed pdf 

(* List bookmarks *)
let output_string_of_target pdf fastrefnums x =
  match Pdfdest.pdfobject_of_destination x with
  | Pdf.Array (_::more) ->
      let a =
        Pdf.Array (Pdf.Integer (Pdfpage.pagenumber_of_target ~fastrefnums pdf x)::more)
      in
        "\"" ^ Pdfwrite.string_of_pdf a ^ "\"" 
  | x -> "\"" ^ Pdfwrite.string_of_pdf x ^ "\""

let json_of_target pdf fastrefnums x =
  match Pdfdest.pdfobject_of_destination x with
  | Pdf.Array (_::more) ->
      let a =
        Pdf.Array (Pdf.Integer (Pdfpage.pagenumber_of_target ~fastrefnums pdf x)::more)
      in
        Cpdfjson.json_of_object pdf (fun _ -> ()) false false a
  | x -> Cpdfjson.json_of_object pdf (fun _ -> ()) false false x

let output_json_marks ch calculate_page_number pdf fastrefnums marks =
  let module J = Cpdfyojson.Safe in
  let json_of_mark m =
    `Assoc
       [("level", `Int m.Pdfmarks.level);
        ("text", `String (Pdftext.utf8_of_pdfdocstring m.Pdfmarks.text));
        ("page", `Int (calculate_page_number m));
        ("open", `Bool m.Pdfmarks.isopen);
        ("target", json_of_target pdf fastrefnums m.Pdfmarks.target)]
  in
  let json = `List (map json_of_mark marks) in
    J.pretty_to_channel ch json

(* List the bookmarks in the given range to the given output *)
let list_bookmarks ~json encoding range pdf output =
  let process_stripped escaped =
    let b = Buffer.create 200 in
      iter
        (fun x ->
           if x <= 127 then Buffer.add_char b (char_of_int x))
        escaped;
      Buffer.contents b
  in
  let process_string s =
    let rec replace c x y = function
    | [] -> []
    | h::t when h = c -> x::y::replace c x y t
    | h::t -> h::replace c x y t
    in
      (* Convert to UTF8, raw, or stripped, and escape backslashed and quotation marks *)
      let codepoints = Pdftext.codepoints_of_pdfdocstring s in
        let escaped =
          let bs = int_of_char '\\'
          and nl = int_of_char '\n'
          and n = int_of_char 'n'
          and q = int_of_char '\"' in
            replace q bs q (replace nl bs n (replace bs bs bs codepoints))
        in
          match encoding with
          | Cpdfmetadata.UTF8 -> Pdftext.utf8_of_codepoints escaped
          | Cpdfmetadata.Stripped -> process_stripped escaped
          | Cpdfmetadata.Raw -> s
    in
      let bookmarks = Pdfmarks.read_bookmarks pdf in
      let refnums = Pdf.page_reference_numbers pdf in
      let rangetable = hashset_of_list range in
      let range_is_all = range = ilist 1 (Pdfpage.endpage pdf) in
      let fastrefnums = hashtable_of_dictionary (combine refnums (indx refnums)) in
        (* Find the pagenumber of each bookmark target. If it is in the range,
         * keep that bookmark. Also keep the bookmark if its target is the null
         * destination. *)
        let inrange =
          keep
            (function x ->
               range_is_all || 
               x.Pdfmarks.target = Pdfdest.NullDestination ||
               (match x.Pdfmarks.target with Pdfdest.NamedDestinationElsewhere _ -> true | _ -> false) ||
               Hashtbl.mem rangetable (Pdfpage.pagenumber_of_target ~fastrefnums pdf x.Pdfmarks.target)) bookmarks
        in
          let calculate_page_number mark =
            (* Some buggy PDFs use integers for page numbers instead of page
             * object references. Adobe Reader and Preview seem to support
             * this, for presumably historical reasons. So if we see a
             * OtherDocPageNumber (which is what Pdfdest parses these as,
             * because that's what they are legitimately, we use this as the
             * page number. It is zero based, though, and we are one-based, so
             * we add one. Pdfpage.pagenumber_of_target has been modified to support this.*)
            Pdfpage.pagenumber_of_target ~fastrefnums pdf mark.Pdfmarks.target
          in
            if json then
              output_json_marks stdout calculate_page_number pdf fastrefnums inrange
            else
              iter
                (function mark ->
                   output.Pdfio.output_string
                     (Printf.sprintf "%i \"%s\" %i%s %s\n"
                       mark.Pdfmarks.level
                       (process_string mark.Pdfmarks.text)
                       (calculate_page_number mark)
                       (if mark.Pdfmarks.isopen then " open" else "")
                       (output_string_of_target pdf fastrefnums mark.Pdfmarks.target)))
                inrange

(* o is the stamp, u is the main pdf page *)

(* \section{Split at bookmarks} *)

let get_bookmark_name pdf marks splitlevel n _ =
  let refnums = Pdf.page_reference_numbers pdf in
  let fastrefnums = hashtable_of_dictionary (combine refnums (indx refnums)) in
  match keep (function m -> n = Pdfpage.pagenumber_of_target ~fastrefnums pdf m.Pdfmarks.target && m.Pdfmarks.level <= splitlevel) marks with
  | {Pdfmarks.text = title}::_ -> Cpdfattach.remove_unsafe_characters Cpdfmetadata.UTF8 title
  | _ -> ""

(* Find the stem of a filename *)
(*let stem s =
  implode (rev (tail_no_fail (dropwhile (neq '.') (rev (explode (Filename.basename s))))))*)

(* Return list, in order, a *set* of page numbers of bookmarks at a given level *)
let bookmark_pages level pdf =
  let refnums = Pdf.page_reference_numbers pdf in
  let fastrefnums = hashtable_of_dictionary (combine refnums (indx refnums)) in
  setify_preserving_order
    (option_map
      (function l when l.Pdfmarks.level = level -> Some (Pdfpage.pagenumber_of_target ~fastrefnums pdf l.Pdfmarks.target) | _ -> None)
      (Pdfmarks.read_bookmarks pdf))

(* Called from cpdflib.ml - different from above *)
let split_on_bookmarks pdf level =
  let points = lose (eq 0) (map pred (bookmark_pages level pdf))
  in let pdf_pages = Pdfpage.pages_of_pagetree pdf in
    let ranges = splitat points (indx pdf_pages) in
      map (fun rs -> Pdfpage.pdf_of_pages pdf rs) ranges
