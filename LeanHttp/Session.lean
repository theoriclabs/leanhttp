import LeanHttp.Error
import LeanHttp.Headers
import LeanHttp.Option

namespace LeanHttp

open Std.Http

structure Session.Config where
  baseUri : Option URI := none
  headers : Headers := .empty
  tls : Tls := .system
  userAgent : String := "leanhttp/0.1"
  encoding : Encoding := .any
  httpVersion : HttpVersion := .default
  proxy : Option URI := none
  noProxy : List String := []
  maxBody : Option Nat := none
  tcpKeepAlive : Bool := true
  deriving Repr

/-- One easy handle plus defaults. A session is not thread-safe. -/
structure Session where
  private handle : FFI.Handle
  config : Session.Config

private def catchCurl (act : IO α) : IO (Except Error α) := do
  try return .ok (← act)
  catch e => return .error (Error.fromIO e)

def available : IO Bool := FFI.available
def version : IO (Except Error String) := catchCurl FFI.version

def Session.new (config : Session.Config := {}) : IO (Except Error Session) := do
  match ← catchCurl FFI.easyInit with
  | .error e => return .error e
  | .ok handle => return .ok { handle, config }

def Session.close (session : Session) : IO Unit :=
  try FFI.close session.handle catch _ => pure ()

private def bodyBytes : Body → IO (Option (Header.Value × ByteArray))
  | .empty => pure none
  | .bytes contentType data => pure (some (contentType, data))
  | .text contentType data => pure (some (contentType, data.toUTF8))
  | .json data => pure (some (Header.Value.ofString! "application/json", data.compress.toUTF8))
  | .form fields => do
      let mut encoded : List String := []
      for (name, value) in fields do
        encoded := encoded ++ [s!"{← FFI.escape name}={← FFI.escape value}"]
      pure (some (Header.Value.ofString! "application/x-www-form-urlencoded", (String.intercalate "&" encoded).toUTF8))

private def resolveUri (base : Option URI) (uri : URI) : URI :=
  match base, uri.authority with
  | some b, none => {
      scheme := b.scheme
      authority := b.authority
      path := if uri.path.isEmpty then b.path else b.path.join uri.path
      query := uri.query
      fragment := uri.fragment }
  | _, _ => uri

private def configureTls (h : FFI.Handle) : Tls → IO Unit
  | .system => do
      Opt.sslVerifyPeer.set h true
      Opt.sslVerifyHost.set h true
  | .bundle ca => do
      Opt.sslVerifyPeer.set h true
      Opt.sslVerifyHost.set h true
      Opt.caInfo.set h ca
  | .mutual ca cert key => do
      Opt.sslVerifyPeer.set h true
      Opt.sslVerifyHost.set h true
      if let some ca := ca then Opt.caInfo.set h ca
      Opt.sslCert.set h cert
      Opt.sslKey.set h key
  | .insecureNoVerify => do
      IO.eprintln "warning: LeanHttp TLS certificate verification is disabled"
      Opt.sslVerifyPeer.set h false
      Opt.sslVerifyHost.set h false

private def configureAuth (h : FFI.Handle) : Auth → IO Unit
  | .none => pure ()
  | .basic user password => Opt.userPwd.set h (user, password)
  | .bearer token => Opt.bearer.set h token

def Session.request (session : Session) (request : Request) : IO (Except Error Response) := do
  catchCurl do
    let h := session.handle
    FFI.reset h
    let uri := resolveUri session.config.baseUri request.uri
    Opt.url.set h uri
    match request.method with
    | .get => Opt.httpGet.set h ()
    | .head => Opt.noBody.set h true
    | method => Opt.customRequest.set h method
    Opt.timeout.set h request.timeouts.total
    Opt.connectTimeout.set h request.timeouts.connect
    match request.redirects with
    | .never => Opt.followLocation.set h false
    | .upTo n =>
        Opt.followLocation.set h true
        Opt.maxRedirs.set h n
    configureTls h session.config.tls
    configureAuth h request.auth
    Opt.userAgent.set h session.config.userAgent
    Opt.acceptEncoding.set h session.config.encoding
    Opt.httpVersion.set h session.config.httpVersion
    Opt.tcpKeepAlive.set h session.config.tcpKeepAlive
    if let some proxy := session.config.proxy then Opt.proxy.set h proxy
    unless session.config.noProxy.isEmpty do Opt.noProxy.set h session.config.noProxy
    if let some max := session.config.maxBody then Opt.maxFileSize.set h max
    let mut headers := overlayHeaders session.config.headers request.headers
    if let some (contentType, bytes) ← bodyBytes request.body then
      headers := (headers.erase Header.Name.contentType).insert Header.Name.contentType contentType
      Opt.postFields.set h bytes
    FFI.setHeaders h (headerLines headers)
    let code ← FFI.perform h
    let rawHeaders ← FFI.responseHeaders h
    let body ← FFI.responseBody h
    let effective ← FFI.effectiveUrl h
    let some status := Status.ofCode none code.toUInt16
      | throw <| IO.userError s!"libcurl returned invalid HTTP status {code}"
    let parsedHeaders ← match parseHeaderBlock rawHeaders with
      | .ok h => pure h
      | .error e => throw <| IO.userError e
    let effectiveUri := (URI.parse? effective).getD uri
    return { status, headers := parsedHeaders, body, effectiveUri }

def Session.withSession (config : Session.Config := {}) (k : Session → IO α) :
    IO (Except Error α) := do
  match ← Session.new config with
  | .error e => return .error e
  | .ok session =>
      try
        let value ← k session
        session.close
        return .ok value
      catch e =>
        session.close
        return .error (Error.fromIO e)

def request (request : Request) : IO (Except Error Response) := do
  match ← Session.new with
  | .error e => return .error e
  | .ok session =>
      let result ← session.request request
      session.close
      return result

def get (uri : URI) (headers : Headers := .empty) : IO (Except Error Response) :=
  request { uri, headers }

def post (uri : URI) (body : Body) (headers : Headers := .empty) : IO (Except Error Response) :=
  request { method := .post, uri, body, headers }

def requestUrl (method : Method) (url : String) (body : Body := .empty)
    (headers : Headers := .empty) : IO (Except Error Response) := do
  let some uri := URI.parse? url | return .error (Error.url url)
  request { method, uri, body, headers }

def getUrl (url : String) (headers : Headers := .empty) : IO (Except Error Response) :=
  requestUrl .get url .empty headers

def postUrl (url : String) (body : Body) (headers : Headers := .empty) :
    IO (Except Error Response) :=
  requestUrl .post url body headers

def requestTask (request : Request) : BaseIO (Task (Except Error Response)) := do
  let task ← IO.asTask (LeanHttp.request request) Task.Priority.dedicated
  return task.map fun
    | .ok result => result
    | .error e => .error (Error.fromIO e)

end LeanHttp
