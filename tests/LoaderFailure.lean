import LeanHttp

open LeanHttp

def main : IO UInt32 := do
  let empty ← Std.Async.Async.block <| requestManyAsync #[]
  unless empty.isEmpty do throw <| IO.userError "empty batch unexpectedly produced results"
  let requests := Array.replicate 3 (Request.get uri!"http://127.0.0.1:1/")
  let results ← Std.Async.Async.block <| requestManyAsync requests { concurrency := 2 }
  unless results.size == requests.size do throw <| IO.userError "loader failure lost batch results"
  for result in results do
    match result with
    | .error { kind := .libraryNotFound _, .. } => pure ()
    | _ => throw <| IO.userError "expected every batch request to report libraryNotFound"
  match ← Session.new with
  | .error { kind := .libraryNotFound _, .. } => return 0
  | .error e => IO.eprintln s!"expected libraryNotFound, got {e}"; return 1
  | .ok s => s.close; IO.eprintln "expected the forced library load to fail"; return 1
