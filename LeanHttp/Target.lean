import Std.Http

namespace LeanHttp

open Std.Http

/-- A reference that cannot replace the base URI's scheme or authority.
    An omitted query inherits the base query only when the path is also empty. -/
structure RelativeRef where
  path : URI.Path
  query : Option URI.Query := none
  fragment : Option String := none
  deriving Repr

/-- Explicit target alternatives. Absolute URIs never inherit the session base. -/
inductive Target where
  | absolute (uri : URI)
  | relative (reference : RelativeRef)
  deriving Repr, Inhabited

instance : Coe URI Target := ⟨.absolute⟩
instance : Coe RelativeRef Target := ⟨.relative⟩

/-- Parse a reference without a scheme or authority. Scheme-relative references
    (`//host/path`) must instead be supplied as explicit absolute URIs. -/
def RelativeRef.parse? (value : String) : Option RelativeRef := do
  let beforeFragment := (value.splitOn "#").head!
  let pathText := (beforeFragment.splitOn "?").head!
  let firstSegment := (pathText.splitOn "/").head!
  -- RFC path-noscheme excludes ':' in the first segment. This also stops a
  -- malformed absolute URL such as "http://" from falling back to a relative path.
  if firstSegment.contains ":" || value.startsWith "//" then none
  else do
    let uri ← URI.parse? ("leanhttp:" ++ value)
    if uri.authority.isSome then none
    else
      return {
        path := uri.path
        query := if beforeFragment.contains "?" then some uri.query else none
        fragment := uri.fragment }

/-- Parse either an absolute URI or a relative reference. HTTP(S) scheme and
    authority requirements are checked during resolution. -/
def Target.parse? (value : String) : Option Target :=
  match URI.parse? value with
  | some uri => some (.absolute uri)
  | none => Target.relative <$> RelativeRef.parse? value

instance : ToString RelativeRef where
  toString reference :=
    let path := toString reference.path
    -- Valid path components can still spell a scheme or authority when joined.
    -- A dot prefix preserves resolution while keeping serialization relative.
    -- It also distinguishes an appended empty segment from an absent path.
    let path := if reference.path.absolute then
        if path.startsWith "//" then "/." ++ path else path
      else if reference.path.segments[0]?.any (fun s =>
          (toString s).isEmpty || (toString s).contains ":") then
        "./" ++ path
      else path
    let query := reference.query.map (fun q => "?" ++ q.toRawString) |>.getD ""
    let fragment := reference.fragment.map (fun f =>
      "#" ++ toString (URI.EncodedFragment.encode f)) |>.getD ""
    path ++ query ++ fragment

instance : ToString Target where
  toString
    | .absolute uri => toString uri
    | .relative reference => toString reference

/-- The path of either kind of target. -/
def Target.path : Target → URI.Path
  | .absolute uri => uri.path
  | .relative reference => reference.path

/-- Query fields, treating an omitted relative query as empty. -/
def Target.query : Target → URI.Query
  | .absolute uri => uri.query
  | .relative reference => reference.query.getD .empty

/-- Replace the target's query with an explicitly supplied query. -/
def Target.withQuery : Target → URI.Query → Target
  | .absolute uri, query => .absolute { uri with query }
  | .relative reference, query => .relative { reference with query := some query }

-- A raw value supplied by the caller is segment data, including '.' and '..'.
-- Keep navigation explicit in reference syntax, and stop both our resolver and
-- libcurl from interpreting these two data values as dot segments.
private def encodeSegment (value : String) : URI.EncodedSegment :=
  if value == "." then URI.EncodedSegment.ofByteArray! "%2E".toUTF8
  else if value == ".." then URI.EncodedSegment.ofByteArray! "%2E%2E".toUTF8
  else URI.EncodedSegment.encode value

/-- Append a raw segment as data, preserving the target's absolute/relative
    meaning. Literal `.` and `..` values are percent-encoded, not navigated. -/
def Target.segment : Target → String → Target
  | .absolute uri, value =>
      let path := uri.path.appendEncoded (encodeSegment value)
      let path := if uri.authority.isSome then { path with absolute := true } else path
      .absolute { uri with path }
  | .relative reference, value =>
      .relative { reference with path := reference.path.appendEncoded (encodeSegment value) }

inductive Target.Error where
  | missingBase
  | invalidBase
  | missingAuthority
  | invalidPath
  | unsupportedScheme
  deriving Repr, DecidableEq

instance Target.instToStringError : ToString Target.Error where
  toString
    | .missingBase => "relative target requires Session.Config.baseUri"
    | .invalidBase => "baseUri must be an absolute HTTP(S) URI with an authority"
    | .missingAuthority => "absolute HTTP target requires an authority"
    | .invalidPath => "HTTP URI path must be empty or start with '/'"
    | .unsupportedScheme => "HTTP targets require an http or https scheme"

/-- The schemes a request target may carry. WebSocket targets use `ws` and
    `wss`; everything else in this package is HTTP. -/
def Target.httpSchemes : List String := ["http", "https"]
def Target.webSocketSchemes : List String := ["ws", "wss"]

private def hasScheme (schemes : List String) (uri : URI) : Bool :=
  schemes.contains (toString uri.scheme)

private def validPath (uri : URI) : Bool :=
  uri.path.absolute || uri.path.isEmpty

-- Std's normalizer removes final '.' and '..' without retaining the directory
-- separator. RFC reference resolution requires that separator to survive.
private def normalizePath (path : URI.Path) : URI.Path :=
  let last := path.segments.back?.map toString
  let normalized := path.normalize
  if last == some "." || last == some ".." then
    { normalized with segments := normalized.segments.push URI.EncodedString.empty }
  else normalized

/-- Resolve a request target whose scheme must be one of `schemes`. Relative
    paths use RFC 3986 directory merging, with explicit query-presence
    semantics and no authority replacement. -/
def Target.resolveIn (schemes : List String) (target : Target) (base : Option URI := none) :
    Except Target.Error URI := do
  match target with
  | .absolute uri =>
      unless hasScheme schemes uri do throw .unsupportedScheme
      unless uri.authority.isSome do throw .missingAuthority
      unless validPath uri do throw .invalidPath
      return { uri with path := normalizePath uri.path }
  | .relative reference =>
      let some base := base | throw .missingBase
      unless hasScheme schemes base && base.authority.isSome && validPath base do throw .invalidBase
      let emptyPath := !reference.path.absolute && reference.path.isEmpty
      let path := if emptyPath then base.path
        else if reference.path.absolute then normalizePath reference.path
        else normalizePath {
          segments := base.path.parent.segments ++ reference.path.segments
          absolute := true }
      let query := reference.query.getD (if emptyPath then base.query else .empty)
      return { base with path, query, fragment := reference.fragment }

/-- Resolve an HTTP request target. -/
def Target.resolve (target : Target) (base : Option URI := none) : Except Target.Error URI :=
  target.resolveIn Target.httpSchemes base

end LeanHttp
