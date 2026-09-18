import LeanHttp.FFI
import LeanHttp.Types

namespace LeanHttp

/- The numeric table is checked against the installed curl headers by
   bindings/curl_options.h. No numeric option escapes this module. -/
private def optUrl : UInt32 := 10002
private def optProxy : UInt32 := 10004
private def optUserPwd : UInt32 := 10005
private def optPostFields : UInt32 := 10015
private def optUserAgent : UInt32 := 10018
private def optSslCert : UInt32 := 10025
private def optCustomRequest : UInt32 := 10036
private def optNoBody : UInt32 := 44
private def optFollowLocation : UInt32 := 52
private def optSslVerifyPeer : UInt32 := 64
private def optCaInfo : UInt32 := 10065
private def optMaxRedirs : UInt32 := 68
private def optHttpGet : UInt32 := 80
private def optConnectOnly : UInt32 := 141
private def optSslVerifyHost : UInt32 := 81
private def optHttpVersion : UInt32 := 84
private def optSslKey : UInt32 := 10087
private def optAcceptEncoding : UInt32 := 10102
private def optHttpAuth : UInt32 := 107
private def optMaxFileSizeLarge : UInt32 := 30117
private def optTimeoutMs : UInt32 := 155
private def optConnectTimeoutMs : UInt32 := 156
private def optNoProxy : UInt32 := 10177
private def optTcpKeepAlive : UInt32 := 213
private def optPathAsIs : UInt32 := 234
private def optBearer : UInt32 := 10220

inductive Opt : Type → Type where
  | url : Opt Std.Http.URI
  | customRequest : Opt Std.Http.Method
  | httpGet : Opt Unit
  | noBody : Opt Bool
  | postFields : Opt ByteArray
  | timeout : Opt Std.Time.Millisecond.Offset
  | connectTimeout : Opt Std.Time.Millisecond.Offset
  | followLocation : Opt Bool
  | maxRedirs : Opt Nat
  | sslVerifyPeer : Opt Bool
  | sslVerifyHost : Opt Bool
  | caInfo : Opt System.FilePath
  | sslCert : Opt System.FilePath
  | sslKey : Opt System.FilePath
  | userAgent : Opt Std.Http.Header.Value
  | acceptEncoding : Opt Encoding
  | httpVersion : Opt HttpVersion
  | proxy : Opt Std.Http.URI
  | noProxy : Opt (List String)
  | userPwd : Opt (String × String)
  | bearer : Opt String
  | tcpKeepAlive : Opt Bool
  | maxFileSize : Opt Nat
  /-- `1` keeps the connection without a transfer; `2` performs a WebSocket
      handshake and then leaves the connection to `curl_ws_send`/`curl_ws_recv`. -/
  | connectOnly : Opt Nat
  /-- Keep the path libcurl was given. `Target.resolve` already performs RFC
      3986 dot-segment removal, and libcurl 8.10 and later would otherwise
      decode `%2E` and navigate with it. -/
  | pathAsIs : Opt Bool

private def boolLong (b : Bool) : Int64 := if b then 1 else 0

def Opt.set (h : FFI.Handle) : Opt α → α → IO Unit
  | .url, uri => FFI.setString h optUrl (toString uri)
  | .customRequest, method => FFI.setString h optCustomRequest (toString method)
  | .httpGet, _ => FFI.setLong h optHttpGet 1
  | .noBody, b => FFI.setLong h optNoBody (boolLong b)
  | .postFields, bytes => FFI.setBytes h optPostFields bytes
  | .timeout, ms => FFI.setLong h optTimeoutMs ms.val.toInt64
  | .connectTimeout, ms => FFI.setLong h optConnectTimeoutMs ms.val.toInt64
  | .followLocation, b => FFI.setLong h optFollowLocation (boolLong b)
  | .maxRedirs, n => FFI.setLong h optMaxRedirs n.toInt64
  | .sslVerifyPeer, b => FFI.setLong h optSslVerifyPeer (boolLong b)
  | .sslVerifyHost, b => FFI.setLong h optSslVerifyHost (if b then 2 else 0)
  | .caInfo, path => FFI.setString h optCaInfo path.toString
  | .sslCert, path => FFI.setString h optSslCert path.toString
  | .sslKey, path => FFI.setString h optSslKey path.toString
  | .userAgent, value => FFI.setString h optUserAgent (toString value)
  | .acceptEncoding, enc => FFI.setString h optAcceptEncoding <| match enc with
      | .identity => "identity"
      | .gzip => "gzip"
      | .any => ""
  | .httpVersion, ver => FFI.setLong h optHttpVersion <| match ver with
      | .default => 0
      | .http11 => 2
      | .http2 => 3
      | .http2Tls => 4
  | .proxy, uri => FFI.setString h optProxy (toString uri)
  | .noProxy, hosts => FFI.setString h optNoProxy (String.intercalate "," hosts)
  | .userPwd, (user, password) => do
      FFI.setString h optUserPwd s!"{user}:{password}"
      FFI.setLong h optHttpAuth 1
  | .bearer, token => do
      FFI.setString h optBearer token
      FFI.setLong h optHttpAuth 64
  | .tcpKeepAlive, b => FFI.setLong h optTcpKeepAlive (boolLong b)
  | .maxFileSize, n => FFI.setLong h optMaxFileSizeLarge n.toInt64
  | .connectOnly, mode => FFI.setLong h optConnectOnly mode.toInt64
  | .pathAsIs, b => FFI.setLong h optPathAsIs (boolLong b)

end LeanHttp
