# Repository workflow

- Maintain `CHANGELOG.md` for user-visible changes. Record additions, fixes,
  changed behavior, and any migration steps.
- Complete changes with an appropriate version bump and release when authorized
  by the task. Keep the Lake version, `LeanHttp.packageVersion`, README install
  tag, changelog section, and Git tag consistent.
- Follow `RELEASING.md` for validation and publication. Run `lake test` before
  releasing; it requires a local loopback HTTP server.
- Preserve existing public APIs where practical. Prefer composable request
  helpers and existing `Std.Http` types over a separate request language.
- Use Lean's expressive types to encode meaningful domain rules: inductive
  alternatives, type-indexed options, and validated values. Keep wire-format
  strings at serialization boundaries; do not add wrappers with no useful invariant.
