import LeanHttp
import Std.Http.Server

open Lean (Json)
open Std LeanHttp Std.Http Std.Async

private def check (condition : Bool) (message : String) : IO Unit := do
  unless condition do throw <| IO.userError s!"FAIL: {message}"

private def expectOk (r : Except LeanHttp.Error α) (what : String) : IO α := do
  match r with
  | .ok value => pure value
  | .error e => throw <| IO.userError s!"FAIL: {what}: {e}"

private structure Inspection where
  method : String
  content_type : String
  default : String
  override : String
  authorization : String
  body : String
  deriving Lean.FromJson

private def response (status : Status) (body : ByteArray)
    (headers : Headers := .empty) : ContextAsync (Response Body.Any) := do
  let full ← (Response.withStatus status).headers headers |>.fromBytes body
  return full

private def handler (request : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  let path := request.line.uri.path.toDecodedSegments.toList
  match path with
  | ["echo"] =>
      let body ← Body.Stream.readAll request.body
      response .ok body (Headers.empty.insert! "X-Method" (toString request.line.method))
  | ["inspect"] =>
      let body ← Body.Stream.readAll request.body
      let json := Json.mkObj [
        ("method", Json.str (toString request.line.method)),
        ("content_type", Json.str (request.line.headers.get? Header.Name.contentType |>.map toString |>.getD "")),
        ("default", Json.str (request.line.headers.get? (Header.Name.ofString! "x-default") |>.map toString |>.getD "")),
        ("override", Json.str (request.line.headers.get? (Header.Name.ofString! "x-override") |>.map toString |>.getD "")),
        ("authorization", Json.str (request.line.headers.get? Header.Name.authorization |>.map toString |>.getD "")),
        ("body", Json.str ((String.fromUTF8? body).getD "<binary>"))]
      let full ← (Response.ok.header Header.Name.contentType (Header.Value.ofString! "application/json")).json json.compress
      return full
  | ["status", code] =>
      let code := code.toNat?.getD 500 |>.toUInt16
      let status := (Status.ofCode none code).getD .internalServerError
      response status s!"status {code}".toUTF8
  | ["redirect"] =>
      response .found ByteArray.empty (Headers.empty.insert! "Location" "/echo")
  | ["redirect", hops] =>
      let n := hops.toNat?.getD 0
      return ← if n == 0 then response .ok "redirected".toUTF8
        else response .found ByteArray.empty <|
          Headers.empty.insert! "Location" s!"/redirect/{n - 1}"
  | ["slow", ms] =>
      IO.sleep (ms.toNat?.getD 0).toUInt32
      response .ok "eventually".toUTF8
  | ["duplicates"] =>
      response .ok ByteArray.empty
        (Headers.empty.insert! "Set-Cookie" "a=1" |>.insert! "Set-Cookie" "b=2")
  | ["large", size] =>
      response .ok (String.ofList (List.replicate (size.toNat?.getD 0) 'x')).toUTF8
  | _ => response .notFound "not found".toUTF8

private def serverUri (port : UInt16) (path : String) : URI :=
  URI.parse! s!"http://127.0.0.1:{port}/{path}"

def main : IO UInt32 := do
  check (← LeanHttp.available) "libcurl is available"
  let version ← expectOk (← LeanHttp.version) "curl version"
  check (version.toLower.contains "libcurl") "version names libcurl"

  let addr : Net.SocketAddress := .v4 {
    addr := Net.IPv4Addr.ofParts 127 0 0 1
    port := 0 }
  let server ← Async.block do
    Server.serve addr (Server.Handler.ofFn handler) { generateDate := false }
  let some boundAddr := server.localAddr | throw <| IO.userError "server has no local address"
  let port := boundAddr.port

  let session ← expectOk (← Session.new {
    headers := Headers.empty.insert! "X-Default" "yes" |>.insert! "X-Override" "old"
    maxBody := some (8 * 1024 * 1024) }) "new session"

  let payload : ByteArray := ByteArray.mk #[0, 1, 2, 0, 255]
  let echoed ← expectOk (← session.request {
    method := .post
    uri := serverUri port "echo"
    headers := Headers.empty.insert! "X-Override" "new"
    body := .bytes (Header.Value.ofString! "application/octet-stream") payload }) "binary echo"
  check (echoed.status == .ok) "echo is 200"
  check (echoed.body == payload) "binary body round-trips including NUL"
  check ((echoed.headers.get? (Header.Name.ofString! "x-method")).map toString == some "POST") "method reaches server"

  let inspected ← expectOk (← session.request {
    method := .patch
    uri := serverUri port "inspect"
    headers := Headers.empty.insert! "X-Override" "new"
    body := .json (Json.mkObj [("ok", Json.bool true)]) }) "inspect"
  let some inspectedText := String.fromUTF8? inspected.body | throw <| IO.userError "inspect response UTF-8"
  let inspectedJson ← match Json.parse inspectedText with
    | .ok json => pure json
    | .error e => throw <| IO.userError e
  check ((inspectedJson.getObjValAs? String "method").toOption == some "PATCH") "custom method"
  check ((inspectedJson.getObjValAs? String "content_type").toOption == some "application/json") "JSON content type"
  check ((inspectedJson.getObjValAs? String "default").toOption == some "yes") "default header"
  check ((inspectedJson.getObjValAs? String "override").toOption == some "new") "request header overrides default"

  let form ← expectOk (← session.request {
    method := .post
    uri := serverUri port "inspect"
    body := .form [("space here", "a+b&c") ] }) "form body"
  let some formText := String.fromUTF8? form.body | throw <| IO.userError "form response UTF-8"
  let formJson ← match Json.parse formText with
    | .ok json => pure json
    | .error e => throw <| IO.userError e
  check ((formJson.getObjValAs? String "content_type").toOption ==
    some "application/x-www-form-urlencoded") "form content type"
  let encodedForm := (formJson.getObjValAs? String "body").toOption
  check (encodedForm == some "space%20here=a%2Bb%26c")
    s!"form fields are percent encoded: {encodedForm}"

  let basic ← expectOk (← session.request {
    uri := serverUri port "inspect"
    auth := .basic "user" "pass" }) "basic auth"
  let some basicText := String.fromUTF8? basic.body | throw <| IO.userError "basic response UTF-8"
  let basicJson ← match Json.parse basicText with
    | .ok json => pure json
    | .error e => throw <| IO.userError e
  check ((basicJson.getObjValAs? String "authorization").toOption ==
    some "Basic dXNlcjpwYXNz") "basic auth header"

  let bearer ← expectOk (← session.request {
    uri := serverUri port "inspect"
    auth := .bearer "secret" }) "bearer auth"
  let some bearerText := String.fromUTF8? bearer.body | throw <| IO.userError "bearer response UTF-8"
  let bearerJson ← match Json.parse bearerText with
    | .ok json => pure json
    | .error e => throw <| IO.userError e
  check ((bearerJson.getObjValAs? String "authorization").toOption ==
    some "Bearer secret") "bearer auth header"

  let typed : Outcome Inspection ← session.getAs (serverUri port "inspect")
  match typed with
  | .ok value _ => check (value.method == "GET") "generic FromJson response codec"
  | .status response => throw <| IO.userError s!"FAIL: typed response status {response.statusCode}"
  | .decode message _ => throw <| IO.userError s!"FAIL: typed response decode: {message}"
  | .transport e => throw <| IO.userError s!"FAIL: typed response transport: {e}"

  let missing ← expectOk (← session.request { uri := serverUri port "status/404" }) "404 response"
  check (missing.status == .notFound) "404 is response data"

  let redirected ← expectOk (← session.request { uri := serverUri port "redirect", redirects := .upTo 2 }) "redirect"
  check (redirected.status == .ok) "redirect followed"

  let notRedirected ← expectOk (← session.request {
    uri := serverUri port "redirect"
    redirects := .never }) "disabled redirect"
  check (notRedirected.status == .found) "redirect can remain a response"

  match ← session.request { uri := serverUri port "redirect/2", redirects := .upTo 1 } with
  | .error { kind := .tooManyRedirects, .. } => pure ()
  | .error e => throw <| IO.userError s!"FAIL: expected tooManyRedirects, got {e}"
  | .ok _ => throw <| IO.userError "FAIL: excess redirects were followed"

  match ← session.request {
    uri := serverUri port "slow/100"
    timeouts := { connect := .ofNat 100, total := .ofNat 10 } } with
  | .error { kind := .timeout, .. } => pure ()
  | .error e => throw <| IO.userError s!"FAIL: expected timeout, got {e}"
  | .ok _ => throw <| IO.userError "FAIL: slow request did not time out"

  let duplicates ← expectOk (← session.request { uri := serverUri port "duplicates" }) "duplicate headers"
  let cookie := Header.Name.ofString! "set-cookie"
  check ((duplicates.headers.getAll? cookie).map (fun values => values.map toString) ==
    some #["a=1", "b=2"])
    "duplicate response headers preserve order"

  let head ← expectOk (← session.request { method := .head, uri := serverUri port "echo" }) "HEAD"
  check (head.status == .ok && head.body.isEmpty) "HEAD returns headers without a body"

  let tiny ← expectOk (← Session.new { maxBody := some 16 }) "tiny session"
  match ← tiny.request { uri := serverUri port "large/17" } with
  | .error { kind := .tooLarge, .. } => pure ()
  | .error e => throw <| IO.userError s!"FAIL: expected tooLarge, got {e}"
  | .ok _ => throw <| IO.userError "FAIL: body over maxBody was accepted"
  tiny.close

  let refused := URI.parse! "http://127.0.0.1:1/"
  match ← LeanHttp.get refused with
  | .error { kind := .couldntConnect, .. } => pure ()
  | .error e => throw <| IO.userError s!"FAIL: expected couldntConnect, got {e}"
  | .ok _ => throw <| IO.userError "FAIL: connection to closed port succeeded"

  let tasks ← (List.range 20).mapM fun _ => requestTask { uri := serverUri port "echo" }
  for task in tasks do
    match task.get with
    | .ok response => check (response.status == .ok) "task response"
    | .error e => throw <| IO.userError s!"FAIL: request task: {e}"

  session.close
  Async.block server.shutdownAndWait
  IO.println "LeanHttp tests passed"
  return 0
