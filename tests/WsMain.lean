import LeanHttp
import LeanWs

open Std LeanHttp Std.Http Std.Async
open LeanWs (Message CloseCode)

/-! WebSocket client tests against an in-process `leanws` server. When the
    loaded libcurl has no WebSocket support the suite instead checks that
    `connect` says so, and stops. Point `LEANHTTP_LIB` at a libcurl built with
    WebSocket support to run the round trips; set `LEANHTTP_TLS_TEST_URL` to a
    `wss://` echo endpoint to add the TLS case. -/

private def check (condition : Bool) (message : String) : IO Unit := do
  unless condition do throw <| IO.userError s!"FAIL: {message}"

private def expectOk (r : Except LeanHttp.Error α) (what : String) : IO α := do
  match r with
  | .ok value => pure value
  | .error e => throw <| IO.userError s!"FAIL: {what}: {e}"

private def expectMessage (r : Except LeanHttp.Error (Option Message)) (what : String) : IO Message := do
  match ← expectOk r what with
  | some message => pure message
  | none => throw <| IO.userError s!"FAIL: {what}: the connection closed"

private partial def echoLoop (session : LeanWs.Session) : Async Unit := do
  match ← session.recv with
  | none => pure ()
  | some message =>
      discard <| session.send message
      echoLoop session

private def upgrade (cookies : IO.Ref (Array String)) (head : Request.Head) (_ : LeanWs.RemoteAddr) :
    Async (Except LeanWs.Handshake.Reject LeanWs.Handshake.Accept) := do
  let cookie := (head.headers.get? (Header.Name.ofString! "cookie")).map (·.value) |>.getD ""
  cookies.modify (·.push cookie)
  return LeanWs.Handshake.server head { subprotocols := ["chat", "json"] }

/-- `/big/N` pushes an `N`-byte binary message before echoing; `/bye` closes
    with `1001`; everything else echoes. -/
private def handler (session : LeanWs.Session) (accept : LeanWs.Handshake.Accept) : Async Unit := do
  match accept.request.uri.path.toDecodedSegments.toList with
  | ["bye"] => session.close .goingAway "server closing"
  | ["big", size] =>
      let size := size.toNat?.getD 0
      discard <| session.send (.binary ⟨Array.replicate size 120⟩)
      echoLoop session
  | _ => echoLoop session

private def serve (cookies : IO.Ref (Array String)) (config : LeanWs.ServerConfig) :
    IO LeanWs.Server := do
  let addr : Net.SocketAddress := .v4 {
    addr := Net.IPv4Addr.ofParts 127 0 0 1
    port := 0 }
  Async.block <| LeanWs.Server.serve addr config (upgrade cookies) handler

private def wsUri (port : UInt16) (path : String) : Target :=
  .absolute (URI.parse! s!"ws://127.0.0.1:{port}/{path}")

private def unsupported : IO UInt32 := do
  match ← WebSocket.connect target!"ws://127.0.0.1:1/" with
  | .error { kind := .websocketUnsupported, detail, .. } =>
      check (!detail.isEmpty) "the unsupported error explains itself"
      IO.println s!"LeanHttp websocket tests skipped: {detail}"
      return 0
  | .error e => IO.eprintln s!"FAIL: expected websocketUnsupported, got {e}"; return 1
  | .ok c => c.close; IO.eprintln "FAIL: connected without WebSocket support"; return 1

private def tlsEndpoint : IO UInt32 := do
  let some url ← IO.getEnv "LEANHTTP_TLS_TEST_URL"
    | IO.println "LeanHttp wss:// test skipped: set LEANHTTP_TLS_TEST_URL"; return 0
  let some target := Target.parse? url
    | throw <| IO.userError s!"FAIL: LEANHTTP_TLS_TEST_URL is not a target: {url}"
  let connection ← expectOk (← WebSocket.connect target) "wss connect"
  expectOk (← connection.send (.text "tls hello")) "wss send"
  -- Public echo endpoints may greet before echoing, so look past a few
  -- messages for the payload.
  let mut echoed := false
  for _ in [0:5] do
    unless echoed do
      let text := match ← expectMessage (← connection.recv) "wss echo" with
        | .text text => text
        | .binary bytes => (String.fromUTF8? bytes).getD ""
      echoed := text == "tls hello"
  check echoed "wss echo returns the sent payload"
  connection.close
  IO.println s!"LeanHttp wss:// echo against {url} passed"
  return 0

def main : IO UInt32 := do
  unless ← WebSocket.supported do return ← unsupported

  let cookies ← IO.mkRef #[]
  let server ← serve cookies {}
  let port := server.localAddr.port
  -- A second listener fragments what it sends, so the client reassembles a
  -- message from continuation frames.
  let fragmented ← serve cookies { limits := { maxFrame := 4096 } }
  let fragmentedPort := fragmented.localAddr.port

  let connection ← expectOk (← WebSocket.connect (wsUri port "echo") {
    subprotocols := ["superchat", "chat"]
    headers := Headers.empty.insert! "Cookie" "session=abc" }) "connect"
  check (connection.subprotocol == some "chat") "server selected an offered subprotocol"
  check ((← cookies.get).contains "session=abc") "the handshake carried the cookie header"
  check (← connection.isOpen) "a fresh connection is open"

  expectOk (← connection.send (.text "hello")) "send text"
  match ← expectMessage (← connection.recv) "text echo" with
  | .text text => check (text == "hello") "text round-trips"
  | .binary _ => throw <| IO.userError "FAIL: text echo returned binary"

  let payload : ByteArray := ⟨#[0, 1, 2, 0, 255]⟩
  expectOk (← connection.send (.binary payload)) "send binary"
  match ← expectMessage (← connection.recv) "binary echo" with
  | .binary bytes => check (bytes == payload) "binary round-trips including NUL"
  | .text _ => throw <| IO.userError "FAIL: binary echo returned text"

  expectOk (← connection.send (.text "")) "send empty text"
  match ← expectMessage (← connection.recv) "empty echo" with
  | .text text => check (text.isEmpty) "an empty message round-trips"
  | .binary bytes => check bytes.isEmpty "an empty message round-trips"

  -- A pong arrives before the next echo and must not surface as a message.
  expectOk (← connection.ping "ping-payload".toUTF8) "ping"
  expectOk (← connection.send (.text "after ping")) "send after ping"
  match ← expectMessage (← connection.recv) "echo after ping" with
  | .text text => check (text == "after ping") "pongs are consumed by recv"
  | .binary _ => throw <| IO.userError "FAIL: echo after ping returned binary"

  match ← connection.ping (ByteArray.mk (Array.replicate 126 65)) with
  | .error { kind := .websocketProtocol, .. } => pure ()
  | _ => throw <| IO.userError "FAIL: an oversized ping payload was accepted"
  connection.close

  -- One frame larger than the receive chunk, delivered in several chunks.
  let big ← expectOk (← WebSocket.connect (wsUri port "big/131072")) "connect for a large frame"
  match ← expectMessage (← big.recv) "large frame" with
  | .binary bytes => check (bytes.size == 131072) s!"large frame arrives whole ({bytes.size} bytes)"
  | .text _ => throw <| IO.userError "FAIL: large frame returned text"
  big.close

  -- Several frames, reassembled into one message.
  let fragments ← expectOk (← WebSocket.connect (wsUri fragmentedPort "big/100000"))
    "connect for a fragmented message"
  match ← expectMessage (← fragments.recv) "fragmented message" with
  | .binary bytes => check (bytes.size == 100000) s!"fragments reassemble ({bytes.size} bytes)"
  | .text _ => throw <| IO.userError "FAIL: fragmented message returned text"
  fragments.close

  -- The message limit is the client's, and failing it closes the connection.
  let limited ← expectOk (← WebSocket.connect (wsUri port "big/4096") {
    limits := { maxMessage := 1024 } }) "connect with a small message limit"
  match ← limited.recv with
  | .error { kind := .websocketProtocol, .. } =>
      check (!(← limited.isOpen)) "a limit failure closes the connection"
      check ((← limited.closeInfo).map (·.code) == some .messageTooBig) "the peer is told 1009"
  | .error e => throw <| IO.userError s!"FAIL: expected websocketProtocol, got {e}"
  | .ok _ => throw <| IO.userError "FAIL: a message over the limit was accepted"
  limited.close

  -- A receive timeout leaves the connection usable.
  let idle ← expectOk (← WebSocket.connect (wsUri port "echo") {
    recvTimeout := .ofNat 50 }) "connect with a short receive timeout"
  match ← idle.recv with
  | .error { kind := .timeout, .. } => pure ()
  | .error e => throw <| IO.userError s!"FAIL: expected timeout, got {e}"
  | .ok _ => throw <| IO.userError "FAIL: an idle connection produced a message"
  expectOk (← idle.send (.text "still here")) "send after a receive timeout"
  match ← expectMessage (← idle.recv) "echo after a receive timeout" with
  | .text text => check (text == "still here") "a timed-out receive does not break the connection"
  | .binary _ => throw <| IO.userError "FAIL: echo after timeout returned binary"
  idle.close

  -- The server closes first.
  let closing ← expectOk (← WebSocket.connect (wsUri port "bye")) "connect to a closing route"
  match ← closing.recv with
  | .ok none =>
      check ((← closing.closeInfo).map (·.code) == some .goingAway) "the peer's close code is kept"
      check (!(← closing.isOpen)) "a closed connection is not open"
  | .ok (some _) => throw <| IO.userError "FAIL: the closing route sent a message"
  | .error e => throw <| IO.userError s!"FAIL: server close: {e}"
  closing.close

  -- A connection closed here answers later calls without reaching libcurl.
  let finished ← expectOk (← WebSocket.connect (wsUri port "echo")) "connect and close"
  finished.close
  match ← finished.recv with
  | .ok none => pure ()
  | _ => throw <| IO.userError "FAIL: recv after close produced a message"
  match ← finished.send (.text "late") with
  | .error { kind := .websocketProtocol, .. } => pure ()
  | _ => throw <| IO.userError "FAIL: send after close was accepted"
  match ← finished.ping with
  | .error { kind := .websocketProtocol, .. } => pure ()
  | _ => throw <| IO.userError "FAIL: ping after close was accepted"
  finished.close

  -- Relative targets resolve against the session base.
  let relative ← expectOk (← WebSocket.connect target!"echo" {
    session := { baseUri := some (URI.parse! s!"ws://127.0.0.1:{port}/") } }) "relative target"
  check (toString relative.uri == s!"ws://127.0.0.1:{port}/echo") "relative target resolves"
  relative.close

  match ← WebSocket.connect target!"http://127.0.0.1:1/" with
  | .error { kind := .unsupportedProtocol, .. } => pure ()
  | _ => throw <| IO.userError "FAIL: an http target was accepted as a websocket target"

  match ← WebSocket.connect target!"/echo" with
  | .error { kind := .urlMalformed, .. } => pure ()
  | _ => throw <| IO.userError "FAIL: a relative target without a base was accepted"

  match ← WebSocket.connect (wsUri 1 "echo") with
  | .error { kind := .couldntConnect, .. } => pure ()
  | .error e => throw <| IO.userError s!"FAIL: expected couldntConnect, got {e}"
  | .ok c => c.close; throw <| IO.userError "FAIL: connected to a closed port"

  -- The async entry points run the blocking calls on worker threads.
  let async ← Async.block do
    let connection ← expectOk (← WebSocket.connectAsync (wsUri port "echo")) "connectAsync"
    expectOk (← connection.sendAsync (.text "async")) "sendAsync"
    let message ← expectMessage (← connection.recvAsync) "recvAsync"
    connection.close
    return message
  match async with
  | .text text => check (text == "async") "the async API round-trips"
  | .binary _ => throw <| IO.userError "FAIL: async echo returned binary"

  let tls ← tlsEndpoint

  Async.block fragmented.shutdown
  Async.block server.shutdown
  if tls != 0 then return tls
  IO.println "LeanHttp websocket tests passed"
  return 0
