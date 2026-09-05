import Lake

open System Lake DSL

package leanhttp where
  version := v!"0.3.0"
  keywords := #["http", "client", "curl", "ffi"]
  license := "MIT"

target leanhttp.o pkg : FilePath := do
  let oFile := pkg.buildDir / "leanhttp.o"
  let srcJob ← inputTextFile <| pkg.dir / "bindings" / "leanhttp.c"
  let optionsJob ← inputTextFile <| pkg.dir / "bindings" / "curl_options.h"
  let srcJob := srcJob.add optionsJob
  let weakArgs := #["-I", (← getLeanIncludeDir).toString, "-I", (pkg.dir / "bindings").toString]
  buildO oFile srcJob weakArgs (traceArgs := #["-fPIC", "-std=c11"]) (extraDepTrace := getLeanTrace)

extern_lib leanhttp pkg := do
  let obj ← leanhttp.o.fetch
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "leanhttp") #[obj]

@[default_target]
lean_lib LeanHttp where
  needs := #[leanhttp]
  precompileModules := true

@[test_driver]
script tests do
  let child ← liftM <| IO.Process.spawn {
    cmd := "bash"
    args := #["run.sh"]
    cwd := "tests" }
  liftM child.wait
