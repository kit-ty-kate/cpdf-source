type colspec =
   NoCol
 | RGB of float * float * float
 | Grey of float
 | CYMK of float * float * float * float

type image =
  JPEG

type drawops =
  | Rect of float * float * float * float
  | Bezier of float * float * float * float * float * float
  | To of float * float
  | Line of float * float
  | ClosePath
  | SetFill of colspec
  | SetStroke of colspec
  | SetLineThickness of float
  | SetLineCap of int
  | SetLineJoin of int
  | SetMiterLimit of float
  | SetDashPattern of float list * float
  | Matrix of Pdftransform.transform_matrix
  | Push
  | Pop
  | Fill
  | FillEvenOdd
  | Stroke
  | FillStroke
  | FillStrokeEvenOdd
  | Clip
  | ClipEvenOdd
  | SoftXObject of drawops list
  | HardXObject of drawops list
  | Image of string
  | ImageXObject of string * Pdf.pdfobject
  | NewPage
  | Opacity of float
  | SOpacity of float
  | Font of Pdftext.standard_font * float
  | Text of string
  | Block of unit (* to fix *)
  | URL of string
  | EndURL

val draw : bool -> int list -> Pdf.t -> drawops list -> Pdf.t
