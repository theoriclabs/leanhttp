import LeanHttp

open LeanHttp

def main : IO UInt32 := do
  match ← Session.new with
  | .error { kind := .libraryNotFound _, .. } => return 0
  | .error e => IO.eprintln s!"expected libraryNotFound, got {e}"; return 1
  | .ok s => s.close; IO.eprintln "expected the forced library load to fail"; return 1
