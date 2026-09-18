import LeanHttp.Session
import LeanWs
import Std.Async

namespace LeanHttp

open Std.Http

/-!
A WebSocket client over libcurl's WebSocket API (libcurl 7.86 and later),
so `wss://` reuses LeanHttp's TLS policy, proxy settings and headers.

Framing is libcurl's; the message types, size limits, fragment reassembly and
close codes are `LeanWs`', so a connection made here and one made by
`LeanWs.Client` carry exactly the same `LeanWs.Message` values.

A connection is a single easy handle and is no more thread-safe than a
`Session`: one task owns it, and `recv` blocks that task's thread until a
message arrives or its timeout expires.
-/

namespace WebSocket

open LeanWs (Message CloseCode CloseInfo Limits)

/- libcurl's `CURLWS_*` frame flags, checked against the installed curl headers
   by bindings/curl_options.h. -/
private def flagText : UInt32 := 1
private def flagBinary : UInt32 := 2
private def flagCont : UInt32 := 4
private def flagClose : UInt32 := 8
private def flagPing : UInt32 := 16
private def flagPong : UInt32 := 64

private def hasFlag (flags mask : UInt32) : Bool := flags &&& mask != 0

/-- Bytes requested from libcurl per receive call. Frames larger than this
    arrive as several chunks. -/
private def chunkSize : UInt32 := 64 * 1024

/-- Client settings for one connection. `session` supplies the same TLS policy,
    proxy, user agent and default headers as an HTTP request; `limits` bounds
    received frames and messages exactly as it does in `LeanWs`. -/
structure Options where
  /-- Subprotocols to offer, in order of preference. -/
  subprotocols : List String := []
  /-- Extra request headers for the handshake, for example a session cookie. -/
  headers : Headers := .empty
  session : Session.Config := {}
  limits : Limits := {}
  /-- Budget for establishing the TCP (and TLS) connection. -/
  connectTimeout : Std.Time.Millisecond.Offset := .ofNat 10000
  /-- Budget for the whole opening handshake. It is cleared afterwards, so it
      never bounds the lifetime of the connection. -/
  handshakeTimeout : Std.Time.Millisecond.Offset := .ofNat 30000
  /-- How long `recv` waits for a message. `0` waits indefinitely. -/
  recvTimeout : Std.Time.Millisecond.Offset := .ofNat 30000
  /-- How long `send` waits for a peer that is not reading. `0` waits
      indefinitely. -/
  sendTimeout : Std.Time.Millisecond.Offset := .ofNat 30000
  deriving Repr

private structure State where
  assembler : LeanWs.Assembler := {}
  /-- The close status, once either side has closed. -/
  closed : Option CloseInfo := none
  sentClose : Bool := false
  handleClosed : Bool := false

/-- An established WebSocket connection. Create one with `connect`; release it
    with `close`, which also sends the closing frame. -/
structure Connection where
  private handle : FFI.Handle
  /-- The resolved `ws://` or `wss://` URI. -/
  uri : URI
  /-- The subprotocol the server selected, if any. -/
  subprotocol : Option String
  options : Options
  private state : IO.Ref State

/-- Whether the loaded libcurl can speak WebSocket at all. `connect` reports
    the same condition as a typed `.websocketUnsupported` error. -/
def supported : IO Bool := FFI.wsSupported

private def unsupportedError (detail : String) : Error :=
  { kind := .websocketUnsupported, code := ⟨4⟩
    message := "libcurl was built without WebSocket support", detail }

/-- Raise a protocol failure the same way the FFI raises libcurl failures, so
    `Error.fromIO` recovers its kind. -/
private def protocolFailure (detail : String) : IO α :=
  throw (IO.Error.otherError 9002 detail)

private def catchCurl (act : IO α) : IO (Except Error α) := do
  try return .ok (← act)
  catch e => return .error (Error.fromIO e)

private def describeTarget : Target.Error → String
  | .missingBase => "relative target requires Session.Config.baseUri"
  | .invalidBase => "baseUri must be an absolute ws:// or wss:// URI with an authority"
  | .missingAuthority => "websocket target requires an authority"
  | .invalidPath => "websocket URI path must be empty or start with '/'"
  | .unsupportedScheme => "websocket targets require a ws or wss scheme"

private def timeoutMs (offset : Std.Time.Millisecond.Offset) : Int64 := offset.val.toInt64

/-- The same budget as a count of milliseconds; negative offsets mean "no
    timeout", exactly as libcurl reads them. -/
private def timeoutNat (offset : Std.Time.Millisecond.Offset) : Nat := offset.val.toNat

private def secWebSocketProtocol : Header.Name := Header.Name.ofString! "sec-websocket-protocol"

/-- The subprotocol the server chose, rejecting one that was not offered. -/
private def negotiated (headers : Headers) (offered : List String) : IO (Option String) := do
  match (headers.getAll? secWebSocketProtocol).getD #[] with
  | #[] => return none
  | #[value] =>
      let name := (toString value).trimAscii.toString
      if offered.contains name then return some name
      else protocolFailure s!"server selected unoffered subprotocol {name}"
  | values => protocolFailure s!"server selected {values.size} subprotocols"

/-- Open a WebSocket connection. The target must be `ws://` or `wss://`;
    a relative target resolves against `opts.session.baseUri`.

    Fails with `.websocketUnsupported` when the loaded libcurl has no
    WebSocket support, and with `.websocketProtocol` when the server answers
    something other than `101` or selects an unoffered subprotocol. -/
def connect (uri : Target) (opts : Options := {}) : IO (Except Error Connection) := do
  match uri.resolveIn Target.webSocketSchemes opts.session.baseUri with
  | .error .unsupportedScheme => return .error {
      kind := .unsupportedProtocol, code := ⟨1⟩,
      message := "unsupported protocol", detail := describeTarget .unsupportedScheme }
  | .error reason => return .error (Error.url (describeTarget reason))
  | .ok target =>
    match ← catchCurl FFI.easyInit with
    | .error error => return .error error
    | .ok handle =>
      unless ← FFI.wsSupported do
        let detail ← FFI.wsDetail
        try FFI.close handle catch _ => pure ()
        return .error (unsupportedError detail)
      let opened ← catchCurl do
        let config := opts.session
        Opt.url.set handle target
        Opt.pathAsIs.set handle true
        -- Mode 2 performs the opening handshake and then hands the connection
        -- to curl_ws_send/curl_ws_recv instead of running a transfer.
        Opt.connectOnly.set handle 2
        Opt.connectTimeout.set handle opts.connectTimeout
        Opt.timeout.set handle opts.handshakeTimeout
        Tls.configure handle config.tls
        Opt.userAgent.set handle config.userAgent
        Opt.tcpKeepAlive.set handle config.tcpKeepAlive
        if let some proxy := config.proxy then Opt.proxy.set handle proxy
        unless config.noProxy.isEmpty do Opt.noProxy.set handle config.noProxy
        let mut headers := overlayHeaders config.headers opts.headers
        unless opts.subprotocols.isEmpty do
          let offered := String.intercalate ", " opts.subprotocols
          let some value := Header.Value.ofString? offered
            | protocolFailure s!"invalid subprotocol list {offered}"
          headers := (headers.erase secWebSocketProtocol).insert secWebSocketProtocol value
        FFI.setHeaders handle (headerLines headers)
        let status ← FFI.perform handle
        unless status == 101 do
          protocolFailure s!"handshake answered {status} instead of 101"
        -- The handshake budget must not outlive the handshake.
        Opt.timeout.set handle (.ofNat 0)
        let responseHeaders ← match parseHeaderBlock (← FFI.responseHeaders handle) with
          | .ok parsed => pure parsed
          | .error message => protocolFailure s!"malformed handshake response: {message}"
        let subprotocol ← negotiated responseHeaders opts.subprotocols
        let state ← IO.mkRef ({} : State)
        return (subprotocol, state)
      match opened with
      | .error error =>
          try FFI.close handle catch _ => pure ()
          return .error error
      | .ok (subprotocol, state) =>
          return .ok { handle, uri := target, subprotocol, options := opts, state }

namespace Connection

/-- The close status once either side has closed, `none` while open. -/
def closeInfo (c : Connection) : BaseIO (Option CloseInfo) := return (← c.state.get).closed

/-- `true` until a close frame has been sent or received. -/
def isOpen (c : Connection) : BaseIO Bool := do
  let state ← c.state.get
  return state.closed.isNone && !state.sentClose && !state.handleClosed

private def sendFrame (c : Connection) (payload : ByteArray) (flags : UInt32) : IO Unit :=
  FFI.wsSend c.handle payload flags (timeoutMs c.options.sendTimeout)

private def markClosed (c : Connection) (info : CloseInfo) : BaseIO Unit :=
  c.state.modify fun state => { state with closed := state.closed.orElse fun _ => some info }

/-- Send our close frame once. -/
private def sendClose (c : Connection) (code : CloseCode) (reason : String) : IO Unit := do
  unless (← c.state.get).sentClose do
    c.state.modify fun state => { state with sentClose := true }
    sendFrame c (LeanWs.Frame.closePayload code reason) flagClose

/-- Fail the connection: report `code` to the peer, then surface `detail`. -/
private def fail (c : Connection) (code : CloseCode) (detail : String) : IO α := do
  markClosed c { code, reason := detail }
  try sendClose c code "" catch _ => pure ()
  protocolFailure detail

private def closeCodeOf : LeanWs.AssembleError → CloseCode
  | .tooLarge _ | .tooManyFragments _ => .messageTooBig
  | .invalidUtf8 => .invalidPayload
  | _ => .protocolError

/-- Accumulate the chunks of one frame until libcurl reports none left.
    `deadline` is a monotonic millisecond stamp, `none` for no timeout. -/
private partial def recvChunks (c : Connection) (deadline : Option Nat) (payload : ByteArray) :
    IO (UInt32 × ByteArray) := do
  let remaining ← match deadline with
    | none => pure (0 : Int64)
    | some deadline => do
        let now ← IO.monoMsNow
        -- A spent budget still asks for 1ms, so an expired deadline is
        -- reported as a timeout by the same path as any other.
        pure (Int64.ofNat (if deadline > now then deadline - now else 1))
  let chunk ← FFI.wsRecv c.handle chunkSize remaining
  let flags ← FFI.wsFrameFlags c.handle
  let bytesLeft := (← FFI.wsFrameBytesLeft c.handle).toNat
  let payload := payload ++ chunk
  let maxFrame := c.options.limits.maxFrame
  if maxFrame > 0 && payload.size + bytesLeft > maxFrame then
    fail c .messageTooBig s!"frame of at least {payload.size + bytesLeft} bytes exceeds the limit"
  if bytesLeft == 0 then return (flags, payload) else recvChunks c deadline payload

private partial def recvMessage (c : Connection) (deadline : Option Nat) : IO (Option Message) := do
  let state ← c.state.get
  if state.closed.isSome || state.handleClosed then return none
  let (flags, payload) ← recvChunks c deadline .empty
  if hasFlag flags flagClose then
    let info ← match LeanWs.Frame.parseClosePayload payload with
      | .ok (some info) => pure info
      | .ok none => pure { code := .noStatus }
      | .error _ => fail c .protocolError "peer sent a malformed close payload"
    markClosed c info
    -- RFC 6455 §5.5.1: answer the peer's close, echoing a code it may repeat.
    let echo := if info.code.isValidOnWire then info.code else .normal
    try sendClose c echo "" catch _ => pure ()
    return none
  if hasFlag flags flagPing then
    -- libcurl does not answer pings; a peer that answers its own would only
    -- see a second, harmless pong.
    sendFrame c payload flagPong
    return ← recvMessage c deadline
  if hasFlag flags flagPong then
    return ← recvMessage c deadline
  let opcode := if state.assembler.inProgress then LeanWs.Opcode.continuation
    else if hasFlag flags flagText then .text else .binary
  let frame : LeanWs.Frame := { fin := !hasFlag flags flagCont, opcode, payload }
  match state.assembler.push c.options.limits frame with
  | .error error => fail c (closeCodeOf error) (toString error)
  | .ok (assembler, message) =>
      c.state.set { state with assembler }
      match message with
      | some message => return some message
      | none => recvMessage c deadline

/-- Receive the next complete message, reassembling fragments and answering
    pings. Returns `none` once the peer has closed or the connection was
    closed here; the status is then available from `closeInfo`.

    `recvTimeout` bounds the whole call, including any ping, pong or
    continuation frames received along the way. Running out of it is a
    `.timeout` error and leaves the connection usable. -/
def recv (c : Connection) : IO (Except Error (Option Message)) := catchCurl do
  let budget := timeoutNat c.options.recvTimeout
  let deadline ← if budget > 0 then pure (some ((← IO.monoMsNow) + budget)) else pure none
  recvMessage c deadline

/-- Send one complete message. Large messages are sent as a single frame;
    `limits.maxFrame` bounds what is received, not what is sent. -/
def send (c : Connection) (message : Message) : IO (Except Error Unit) := catchCurl do
  if (← c.state.get).sentClose then
    protocolFailure "websocket has already sent its close frame"
  sendFrame c message.payload (if message.isText then flagText else flagBinary)

/-- Send a ping. The peer's pong is consumed by `recv`. -/
def ping (c : Connection) (payload : ByteArray := .empty) : IO (Except Error Unit) := catchCurl do
  if (← c.state.get).sentClose then
    protocolFailure "websocket has already sent its close frame"
  if payload.size > 125 then
    protocolFailure s!"ping payload of {payload.size} bytes exceeds 125"
  sendFrame c payload flagPing

/-- Send the closing frame, if one has not been sent, and release the
    connection. Safe to call more than once. Closing does not wait for the
    peer's answering frame; `recv` returns `none` once it arrives. -/
def close (c : Connection) (code : CloseCode := .normal) (reason : String := "") : IO Unit := do
  unless (← c.state.get).handleClosed do
    try sendClose c code reason catch _ => pure ()
    c.state.modify fun state => { state with handleClosed := true }
    try FFI.close c.handle catch _ => pure ()

/-- Send a message on a dedicated worker thread. One task at a time owns a
    connection; concurrent use of the same connection is not supported. -/
def sendTask (c : Connection) (message : Message) : BaseIO (Task (Except Error Unit)) := do
  let task ← IO.asTask (c.send message) Task.Priority.dedicated
  return task.map fun
    | .ok result => result
    | .error error => .error (Error.fromIO error)

/-- Receive a message on a dedicated worker thread, so a blocking receive never
    occupies the async scheduler. -/
def recvTask (c : Connection) : BaseIO (Task (Except Error (Option Message))) := do
  let task ← IO.asTask c.recv Task.Priority.dedicated
  return task.map fun
    | .ok result => result
    | .error error => .error (Error.fromIO error)

/-- Await `send` without blocking the async scheduler. -/
def sendAsync (c : Connection) (message : Message) : Std.Async.Async (Except Error Unit) := do
  Std.Async.Async.ofTask (← c.sendTask message)

/-- Await `recv` without blocking the async scheduler. Dropping this action
    does not cancel the receive; it runs until its timeout. -/
def recvAsync (c : Connection) : Std.Async.Async (Except Error (Option Message)) := do
  Std.Async.Async.ofTask (← c.recvTask)

end Connection

/-- Open a connection, run `k`, and close the connection on both the normal
    and the failing path. -/
def withConnection (uri : Target) (opts : Options := {}) (k : Connection → IO α) :
    IO (Except Error α) := do
  match ← connect uri opts with
  | .error error => return .error error
  | .ok connection =>
      try
        let value ← k connection
        connection.close
        return .ok value
      catch error =>
        connection.close
        return .error (Error.fromIO error)

/-- Connect on a dedicated worker thread, which owns the handshake. -/
def connectTask (uri : Target) (opts : Options := {}) : BaseIO (Task (Except Error Connection)) := do
  let task ← IO.asTask (connect uri opts) Task.Priority.dedicated
  return task.map fun
    | .ok result => result
    | .error error => .error (Error.fromIO error)

/-- Await a connection without blocking the async scheduler. -/
def connectAsync (uri : Target) (opts : Options := {}) :
    Std.Async.Async (Except Error Connection) := do
  Std.Async.Async.ofTask (← connectTask uri opts)

end WebSocket

end LeanHttp
