## Official release

1. Add the version bump as the final, separate commit on the feature branch.
2. Merge the branch through a reviewed pull request, then wait for the
   post-merge Build Check on `master` to pass at the merge commit.
3. Create one annotated `X.Y.Z` tag targeting that exact green merge commit
   and push the tag once. Never retag or delete and re-push it.
4. `.github/workflows/release.yml` builds the Release app, signs nested native
   artifacts and the app with Developer ID, notarizes and staples the app and
   DMG, publishes the GitHub Release, and updates Homebrew.

Signing and notarization credentials are held in GitHub Actions secrets. After
the workflow succeeds, verify the GitHub assets, checksums, signatures,
notarization, and Homebrew installation. Delete the branch and worktree only
after those checks pass.

## Legacy local notarization helper

`notarize_app.sh` assumes native artifacts are already built. It is not
release-complete, is not a supported recovery path, and must not be used to
qualify a release artifact. GitHub Actions is the only supported release
signing and notarization path.

```shell
./notarize_app.sh "$CODE_SIGN_IDENTITY"
```

Example:
```shell
./notarize_app.sh "Developer ID Application: AAAA BBBB (XXXXX)"
```
