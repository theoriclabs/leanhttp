import LeanHttp.Types

namespace LeanHttp

open Std.Http

private def splitHeader (line : String) : Option (String × String) :=
  match line.splitOn ":" with
  | [] | [_] => none
  | name :: rest => some (name, String.intercalate ":" rest)

private def stripCR (s : String) : String :=
  if s.endsWith "\r" then (s.dropEnd 1).toString else s

/-- Parse libcurl's raw header callback bytes, retaining only the final
    response block and preserving duplicate fields in order. -/
def parseHeaderBlock (raw : ByteArray) : Except String Headers := do
  let some text := String.fromUTF8? raw | throw "response headers are not UTF-8"
  let mut pairs : List (String × String) := []
  for rawLine in text.splitOn "\n" do
    let line := stripCR rawLine
    if line.startsWith "HTTP/" then
      pairs := []
    else if line.isEmpty then
      pure ()
    else if line.startsWith " " || line.startsWith "\t" then
      match pairs with
      | [] => throw "folded response header without a preceding field"
      | (n, v) :: rest => pairs := (n, v ++ " " ++ line.trimAscii.toString) :: rest
    else
      let some (name, value) := splitHeader line | throw s!"malformed response header: {line}"
      pairs := (name, value.trimAscii.toString) :: pairs
  let mut out : List (Header.Name × Header.Value) := []
  for (name, value) in pairs.reverse do
    let some name := Header.Name.ofString? name | throw s!"invalid response header name: {name}"
    let some value := Header.Value.ofString? value | throw s!"invalid response header value for {name}"
    out := out ++ [(name, value)]
  return Headers.ofList out

/-- Session defaults with request fields replacing every default of the same name. -/
def overlayHeaders (defaults request : Headers) : Headers :=
  (defaults.filter fun name _ => !request.contains name).merge request

def headerLines (headers : Headers) : Array String :=
  headers.toArray.map fun (name, value) => s!"{name}: {value}"

end LeanHttp
