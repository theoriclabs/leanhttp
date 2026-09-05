# Releasing LeanHttp

Maintain `CHANGELOG.md` for every user-visible change. Collect changes under
`Unreleased` while developing, then move them into a dated version section when
releasing. Describe observable behavior and any migration steps.

## Prepare

1. Choose the version. Use a patch release for compatible fixes and a minor
   release for new capabilities. Before 1.0, document any breaking changes
   explicitly in the minor release notes.
2. Update `lakefile.lean`, `LeanHttp/Version.lean`, and the installation tag in
   `README.md` together. The session's default user agent uses `packageVersion`.
   The separate test package's version is independent of the library version.
3. Add the dated changelog section, leave an `Unreleased` section at the top,
   and update the release and comparison links.
4. Run `lake test`. It compiles the DSL and invalid-literal checks, then runs the
   local HTTP, async, and forced loader-failure suites. These tests need loopback
   socket access. Check README examples with the pinned Lean toolchain as well.
5. Review the diff, commit the release changes, and confirm that the working
   tree is clean and the release includes the current remote `main`.

## Publish

Use the release's changelog section as its GitHub release notes. Put the exact
notes in a temporary file and pass it to `gh release create --notes-file`.

For a version such as `0.2.0`, after the checks above:

```bash
git tag -a v0.2.0 -m "LeanHttp 0.2.0"
git push --atomic origin main v0.2.0
gh release create v0.2.0 --repo theoriclabs/leanhttp --verify-tag \
  --title "LeanHttp 0.2.0" --notes-file /path/to/release-notes.md
```

Use the version being released in place of the example. Publish only the
validated commit. Do not move an existing release tag; make a new release for
subsequent code changes. If branch protection requires a pull request, merge
through the required process before tagging the resulting commit.

Finally, verify that the remote tag points to the tested commit and the GitHub
release is published with the expected notes. Report its URL. Source-only
releases use GitHub's generated source archives; no native binaries are required.
