import LeanHttp.FFI

namespace LeanHttp

/-- A libcurl result code, preserved verbatim. -/
structure CURLcode where
  toUInt32 : UInt32
  deriving DecidableEq, Repr, Hashable

inductive SslFailure where
  | connectError
  | peerCertificate
  | caCert
  | cipher
  | clientCert
  | other
  deriving DecidableEq, Repr

/-- Stable failure categories. HTTP response statuses are not transport errors. -/
inductive Error.Kind where
  | libraryNotFound (searched : List String)
  | unsupportedProtocol
  | urlMalformed
  | couldntResolveProxy
  | couldntResolveHost
  | couldntConnect
  | timeout
  | tooManyRedirects
  | ssl (detail : SslFailure)
  | sendRecv
  | tooLarge
  | aborted
  | other
  deriving DecidableEq, Repr

structure Error where
  kind : Error.Kind
  code : CURLcode
  message : String
  detail : String
  deriving Repr

private def messageOf : UInt32 → String
  | 1 => "unsupported protocol"
  | 3 => "malformed URL"
  | 5 => "could not resolve proxy"
  | 6 => "could not resolve host"
  | 7 => "could not connect"
  | 18 => "partial transfer"
  | 23 => "write callback failed"
  | 28 => "operation timed out"
  | 35 => "TLS connection failed"
  | 42 => "operation aborted"
  | 47 => "too many redirects"
  | 51 => "peer certificate or fingerprint did not match"
  | 52 => "server returned no data"
  | 55 => "send failed"
  | 56 => "receive failed"
  | 58 => "local client certificate problem"
  | 59 => "could not use requested TLS cipher"
  | 60 => "peer certificate could not be authenticated"
  | 63 => "response exceeded configured size"
  | 77 => "could not read CA certificate"
  | 9000 => "libcurl was not found"
  | _ => "libcurl transport failure"

def Error.kindOf : UInt32 → Error.Kind
  | 1 => .unsupportedProtocol
  | 3 => .urlMalformed
  | 5 => .couldntResolveProxy
  | 6 => .couldntResolveHost
  | 7 => .couldntConnect
  | 18 | 23 | 52 | 55 | 56 => .sendRecv
  | 28 => .timeout
  | 35 => .ssl .connectError
  | 42 => .aborted
  | 47 => .tooManyRedirects
  | 51 | 60 => .ssl .peerCertificate
  | 58 => .ssl .clientCert
  | 59 => .ssl .cipher
  | 63 => .tooLarge
  | 77 => .ssl .caCert
  | 9000 => .libraryNotFound []
  | _ => .other

/-- Decode the `IO.Error.otherError` emitted by the FFI. -/
def Error.ofIO : IO.Error → Option Error
  | .otherError code detail => some {
      kind := Error.kindOf code
      code := ⟨code⟩
      message := messageOf code
      detail }
  | _ => none

def Error.fromIO (e : IO.Error) : Error :=
  (Error.ofIO e).getD {
    kind := .other
    code := ⟨9001⟩
    message := "foreign IO failure"
    detail := toString e }

def Error.url (s : String) : Error := {
  kind := .urlMalformed
  code := ⟨3⟩
  message := "malformed URL"
  detail := s }

instance : ToString Error where
  toString e :=
    let detail := if e.detail.isEmpty then "" else s!": {e.detail}"
    s!"[{e.code.toUInt32}] {e.message}{detail}"

end LeanHttp
