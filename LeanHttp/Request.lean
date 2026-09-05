import LeanHttp.Types

namespace LeanHttp

open Std.Http

/-- Encode a value explicitly as JSON, including values such as `String` that
    otherwise have a plain-text body codec. -/
def Body.ofJson [Lean.ToJson α] (value : α) : Body :=
  .json (Lean.toJson value)

/-- Construct a GET request. The returned record can still be updated normally. -/
def Request.get (uri : Target) : Request := { uri }

/-- Construct a POST request. -/
def Request.post (uri : Target) : Request := { method := .post, uri }

/-- Construct a PUT request. -/
def Request.put (uri : Target) : Request := { method := .put, uri }

/-- Construct a PATCH request. -/
def Request.patch (uri : Target) : Request := { method := .patch, uri }

/-- Construct a DELETE request. -/
def Request.delete (uri : Target) : Request := { method := .delete, uri }

/-- Construct a HEAD request. -/
def Request.head (uri : Target) : Request := { method := .head, uri }

/-- Replace the request body with a JSON-encoded value. -/
def Request.json [Lean.ToJson α] (request : Request) (value : α) : Request :=
  { request with body := Body.ofJson value }

/-- Replace the request's authentication with bearer authentication. -/
def Request.bearer (request : Request) (token : String) : Request :=
  { request with auth := .bearer token }

/-- Replace the request's authentication with basic authentication. -/
def Request.basic (request : Request) (user password : String) : Request :=
  { request with auth := .basic user password }

/-- Replace every request header with this name with one value. -/
def Request.header (request : Request) (name : Header.Name) (value : Header.Value) : Request :=
  { request with headers := (request.headers.erase name).insert name value }

/-- Append a header, preserving existing fields with the same name. -/
def Request.addHeader (request : Request) (name : Header.Name) (value : Header.Value) : Request :=
  { request with headers := request.headers.insert name value }

-- Lean 4.33's query encoder leaves literal '+' unchanged, while its decoder
-- treats '+' as space. Restrict the encoding rule, then validate the generated
-- bytes under Std's standard query type. No user input is parsed as encoded data.
private def encodeQueryParam (value : String) : URI.EncodedQueryParam :=
  let encoded := URI.EncodedQueryString.encode value
    (fun c => Std.Http.Internal.Char.isQueryDataChar c && c != '+'.toUInt8)
  URI.EncodedQueryParam.ofByteArray! encoded.toByteArray

/-- Append a query parameter, encoding the raw name and value. Repeated names
    are preserved in order. Pass unescaped strings to avoid double encoding. -/
def Request.param (request : Request) (name value : String) : Request :=
  { request with uri := request.uri.withQuery <|
      request.uri.query.insertEncoded (encodeQueryParam name) (some (encodeQueryParam value)) }

/-- Append one raw path segment using Std's percent encoding. A slash in the
    value stays within that segment. Existing path segments are preserved. -/
def Request.segment (request : Request) (value : String) : Request :=
  { request with uri := request.uri.segment value }

end LeanHttp
