import LeanHttp.Types

namespace LeanHttp

/-- A URI literal validated at compile time. Use `Std.Http.URI.parse?` for
    dynamic strings. This checks URI syntax, not HTTP protocol support. -/
scoped macro:max "uri!" value:str : term => do
  if (Std.Http.URI.parse? value.getString).isNone then
    Lean.Macro.throwErrorAt value "invalid URI literal"
  `(Std.Http.URI.parse! $value)

/-- A header name literal validated at compile time. -/
scoped macro:max "headerName!" value:str : term => do
  if (Std.Http.Header.Name.ofString? value.getString).isNone then
    Lean.Macro.throwErrorAt value "invalid header name literal"
  `(Std.Http.Header.Name.ofString! $value)

/-- A header value literal validated at compile time. Use
    `Std.Http.Header.Value.ofString?` for dynamic strings. -/
scoped macro:max "headerValue!" value:str : term => do
  if (Std.Http.Header.Value.ofString? value.getString).isNone then
    Lean.Macro.throwErrorAt value "invalid header value literal"
  `(Std.Http.Header.Value.ofString! $value)

end LeanHttp
