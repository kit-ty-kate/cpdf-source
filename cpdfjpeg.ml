open Pdfutil
open Pdfio

(* Return the width and height of a JPEG image, per Michael Petrov's C version. *)
exception Answer of int * int

let jpeg_dimensions bs =
  try
    let get = bget bs in
    let i = ref 0 in
    if get !i = 0xFF && get (!i + 1) = 0xD8 && get (!i + 2) = 0xFF && get (!i + 3) = 0xE0 then
      begin
        i += 4;
        if
             get (!i + 2) = int_of_char 'J' && get (!i + 3) = int_of_char 'F'
          && get (!i + 4) = int_of_char 'I' && get (!i + 5) = int_of_char 'F'
          && get (!i + 6) = 0
        then
          let block_length = ref (get !i * 256 + get (!i + 1)) in
            while !i < bytes_size bs do
              i := !i + !block_length;
              if !i > bytes_size bs then raise (Pdf.PDFError "jpeg_dimensions: too short") else
              if get !i <> 0xFF then raise (Pdf.PDFError "jpeg_dimensions: not a valid block") else
              if get (!i + 1) = 0xC0 then
                raise (Answer (get (!i + 7) * 256 + get (!i + 8), (get (!i + 5) * 256 + get (!i + 6))))
              else
                begin
                  i += 2;
                  block_length := get !i * 256 + get (!i + 1)
                end
            done
        else
          raise (Pdf.PDFError "jpeg_dimensions: Not a valid JFIF string")
      end
    else
      raise (Pdf.PDFError "jpeg_dimensions: Not a valid SOI header");
    assert false
 with
   Answer (w, h) -> (w, h)
