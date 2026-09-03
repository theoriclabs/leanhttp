namespace LeanHttp.FFI

@[extern "leanhttp_initialize"]
private opaque init : IO Unit
builtin_initialize init

opaque T : NonemptyType.{0}
instance : Nonempty T.type := T.property

/-- An opaque `CURL *` easy handle owned by the Lean runtime. -/
def Handle : Type := T.type
deriving Nonempty

instance : Repr Handle where
  reprPrec _ _ := "#<CURL *>"

@[extern "leanhttp_available"] opaque available : IO Bool
@[extern "leanhttp_version"] opaque version : IO String
@[extern "leanhttp_easy_init"] opaque easyInit : IO Handle
@[extern "leanhttp_easy_reset"] opaque reset : @&Handle → IO Unit
@[extern "leanhttp_setopt_long"] opaque setLong : @&Handle → UInt32 → Int64 → IO Unit
@[extern "leanhttp_setopt_string"] opaque setString : @&Handle → UInt32 → String → IO Unit
@[extern "leanhttp_setopt_bytes"] opaque setBytes : @&Handle → UInt32 → @&ByteArray → IO Unit
@[extern "leanhttp_set_headers"] opaque setHeaders : @&Handle → @&Array String → IO Unit
@[extern "leanhttp_perform"] opaque perform : @&Handle → IO UInt32
@[extern "leanhttp_response_headers"] opaque responseHeaders : @&Handle → IO ByteArray
@[extern "leanhttp_response_body"] opaque responseBody : @&Handle → IO ByteArray
@[extern "leanhttp_effective_url"] opaque effectiveUrl : @&Handle → IO String
@[extern "leanhttp_close"] opaque close : @&Handle → IO Unit
@[extern "leanhttp_escape"] opaque escape : String → IO String

end LeanHttp.FFI
