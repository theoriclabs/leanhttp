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
    let query := reference.query.map (fun q => "?" ++ q.toRawString) |>.getD ""
    let fragment := reference.fragment.map ("#" ++ ·) |>.getD ""
    toString reference.path ++ query ++ fragment

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

/-- Append a raw segment, preserving the target's absolute/relative meaning. -/
def Target.segment : Target → String → Target
  | .absolute uri, value =>
      let path := uri.path.append value
      let path := if uri.authority.isSome then { path with absolute := true } else path
      .absolute { uri with path }
  | .relative reference, value =>
      .relative { reference with path := reference.path.append value }

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

private def isHttp (uri : URI) : Bool :=
  toString uri.scheme == "http" || toString uri.scheme == "https"

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

/-- Resolve an HTTP request target. Relative paths use RFC 3986 directory
    merging, with explicit query-presence semantics and no authority replacement. -/
def Target.resolve (target : Target) (base : Option URI := none) : Except Target.Error URI := do
  match target with
  | .absolute uri =>
      unless isHttp uri do throw .unsupportedScheme
      unless uri.authority.isSome do throw .missingAuthority
      unless validPath uri do throw .invalidPath
      return uri
  | .relative reference =>
      let some base := base | throw .missingBase
      unless isHttp base && base.authority.isSome && validPath base do throw .invalidBase
      let emptyPath := !reference.path.absolute && reference.path.isEmpty
      let path := if emptyPath then base.path
        else if reference.path.absolute then normalizePath reference.path
        else normalizePath {
          segments := base.path.parent.segments ++ reference.path.segments
          absolute := true }
      let query := reference.query.getD (if emptyPath then base.query else .empty)
      return { base with path, query, fragment := reference.fragment }

end LeanHttp
