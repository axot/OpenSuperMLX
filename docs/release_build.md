## Official release

1. Add the version bump as the final, separate commit on the feature branch.
2. Merge the branch into `master`, then wait for the post-merge Build Check to
   pass at the merge commit.
3. Create one annotated `X.Y.Z` tag targeting that exact green merge commit
   and push the tag once. Never retag or delete and re-push it.
4. `.github/workflows/release.yml` builds the Release app, signs nested native
   artifacts and the app with Developer ID, notarizes and staples the app and
   DMG, publishes the GitHub Release, and updates Homebrew.

In-app updates use Sparkle. The workflow signs Sparkle's helpers with Developer
ID, signs the final DMG with the `SPARKLE_ED_PRIVATE_KEY` secret, verifies that
signature against the app's `SUPublicEDKey`, and publishes `appcast.xml` with
the release. The app reads it from
`https://github.com/axot/OpenSuperMLX/releases/latest/download/appcast.xml`.
The release fails if the secret is missing or does not match the public key.
Sparkle compares `CURRENT_PROJECT_VERSION`, so the release preflight rejects a
tag whose build number is not greater than the previous release's.
Keep an offline backup of the private key: installed copies reject updates
signed with any other key.

Signing and notarization credentials are held in GitHub Actions secrets. After
the workflow succeeds, verify the GitHub assets, checksums, signatures,
notarization, and Homebrew installation. Delete the branch only after those
checks pass.

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
