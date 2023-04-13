(* UNICODE, INC. LICENSE AGREEMENT - DATA FILES AND SOFTWARE

Unicode Data Files include all data files under the directories
http://www.unicode.org/Public/, http://www.unicode.org/reports/, and
http://www.unicode.org/cldr/data/. Unicode Data Files do not include PDF online
code charts under the directory http://www.unicode.org/Public/. Software
includes any source code published in the Unicode Standard or under the
directories http://www.unicode.org/Public/, http://www.unicode.org/reports/,
and http://www.unicode.org/cldr/data/.

NOTICE TO USER: Carefully read the following legal agreement. BY DOWNLOADING,
INSTALLING, COPYING OR OTHERWISE USING UNICODE INC.'S DATA FILES ("DATA
FILES"), AND/OR SOFTWARE ("SOFTWARE"), YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO
BE BOUND BY, ALL OF THE TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT
AGREE, DO NOT DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR
SOFTWARE.

COPYRIGHT AND PERMISSION NOTICE

Copyright © 1991-2015 Unicode, Inc. All rights reserved. Distributed under the
Terms of Use in http://www.unicode.org/copyright.html.

Permission is hereby granted, free of charge, to any person obtaining a copy of
the Unicode data files and any associated documentation (the "Data Files") or
Unicode software and any associated documentation (the "Software") to deal in
the Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell copies
of the Data Files or Software, and to permit persons to whom the Data Files or
Software are furnished to do so, provided that

(a) this copyright and permission notice appear with all copies of the Data
Files or Software, (b) this copyright and permission notice appear in
associated documentation, and (c) there is clear notice in each modified Data
File or in the Software as well as in the documentation associated with the
Data File(s) or Software that the data or software has been modified.  THE DATA
FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF THIRD PARTY RIGHTS. IN
NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE BE
LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES, OR ANY
DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall not be
used in advertising or otherwise to promote the sale, use or other dealings in
these Data Files or Software without prior written authorization of the
copyright holder. *)

open Pdfutil

let unicodedata_source = __DATA:UnicodeData.txt

type t =
  {code_value : string;
   character_name : string;
   general_category : string;
   canonical_combining_classes : string;
   bidirectional_category : string;
   character_decomposition_mapping : string;
   decimal_digit_value : string;
   digit_value : string;
   numeric_value : string;
   mirrored : string;
   unicode_10_name : string;
   iso_10646_comment_field : string;
   uppercase_mapping : string;
   lowercase_mapping : string;
   titlecase_mapping : string}

let get_single_field i =
  let r = implode (Pdfread.getuntil true (function c -> c = ';' || c = '\n') i) in
    Pdfio.nudge i;
    r

let parse_entry i =
  let code_value = get_single_field i in
  let character_name = get_single_field i in
  let general_category = get_single_field i in
  let canonical_combining_classes = get_single_field i in
  let bidirectional_category = get_single_field i in
  let character_decomposition_mapping = get_single_field i in
  let decimal_digit_value = get_single_field i in
  let digit_value = get_single_field i in
  let numeric_value = get_single_field i in
  let mirrored = get_single_field i in
  let unicode_10_name = get_single_field i in
  let iso_10646_comment_field = get_single_field i in
  let uppercase_mapping = get_single_field i in
  let lowercase_mapping = get_single_field i in
  let titlecase_mapping = get_single_field i in
    {code_value;
     character_name;
     general_category;
     canonical_combining_classes;
     bidirectional_category;
     character_decomposition_mapping;
     decimal_digit_value;
     digit_value;
     numeric_value;
     mirrored;
     unicode_10_name;
     iso_10646_comment_field;
     uppercase_mapping;
     lowercase_mapping;
     titlecase_mapping}

let rec parse_unicodedata a i =
  if i.Pdfio.pos_in () = i.Pdfio.in_channel_length + 2 (* it's been nudged *)
    then rev a
    else parse_unicodedata (parse_entry i::a) i

let print_entry e =
  Printf.printf
    "{{%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s}}\n"
    e.code_value
    e.character_name
    e.general_category
    e.canonical_combining_classes
    e.bidirectional_category
    e.character_decomposition_mapping
    e.decimal_digit_value
    e.digit_value
    e.numeric_value
    e.mirrored
    e.unicode_10_name
    e.iso_10646_comment_field
    e.uppercase_mapping
    e.lowercase_mapping
    e.titlecase_mapping

let unicodedata =
  memoize
    (fun () ->
       let r = 
          unicodedata_source
       |> Pdfio.bytes_of_string
       |> Pdfcodec.decode_flate
       |> Pdfio.string_of_bytes
       |> Pdfio.input_of_string
       |> parse_unicodedata []
       in (*iter print_entry r;*) r)
