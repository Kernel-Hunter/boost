# Releasing Boost

A release has two halves. GitHub Actions builds and publishes the zip. Then
the maintainer signs that zip on their own Mac and adds it to the update
feed, which is what makes installed copies offer the update.

## Steps

1. Bump `VERSION` in `Scripts/build.sh`, commit, and push to `main`.
2. Tag and push the tag:

   ```bash
   git tag v1.5.0
   git push origin v1.5.0
   ```

   `.github/workflows/release.yml` checks that the tag matches `VERSION`, runs
   the tests, builds `Boost.zip`, and publishes the release with the zip's
   SHA-256 in the notes. Wait for it to finish.
3. Add the release to the update feed:

   ```bash
   swift build                # once, so Sparkle's tools are in .build/artifacts
   ./Scripts/appcast.sh 1.5.0
   git push
   ```

   The script downloads the published zip, checks it against the SHA-256 in
   the release notes, checks that the app inside is 1.5.0 and carries our
   public key, signs the zip with the EdDSA key from your login Keychain, and
   commits the new item in `docs/appcast.xml`. The first time, macOS asks
   whether `sign_update` may use the key. Choose Always Allow.
4. GitHub Pages republishes `docs/` within a minute or two. Check that
   <https://kernel-hunter.github.io/boost/appcast.xml> lists the new version.
5. Update the Homebrew cask in `Kernel-Hunter/homebrew-boost` with the new
   version and SHA-256, as before.

Until step 3 is pushed, nobody is offered the update, so forgetting it only
means people update later.

## How updates work

Boost uses [Sparkle](https://sparkle-project.org) 2, pinned in
`Package.swift`. The app reads `SUFeedURL` (the appcast above) and
`SUPublicEDKey` from its Info.plist, both set in `Scripts/build.sh`.

- **Nothing is checked until the user agrees.** Sparkle asks on the second
  launch whether to check automatically. "Check for Updates…" in the Boost
  menu and the toggle in Settings work at any time.
- **Nothing is installed without a click.** `SUAllowsAutomaticUpdates` is off.
- **Every update must be signed with our EdDSA key.** The app refuses a zip
  whose signature does not match the public key it shipped with, before it
  replaces anything.

## The signing key

The private key lives in the maintainer's login Keychain, where Sparkle's
`generate_keys` put it. It is deliberately not a GitHub secret: whoever holds
it can push an update to every Boost user, so it stays on one machine. Keep an
offline backup (`generate_keys -x <file>`). If the Keychain is unavailable,
`SPARKLE_KEY_FILE=<that file> ./Scripts/appcast.sh <version>` signs with the
backup instead.

If the key is ever lost, installed copies can no longer be updated through
Sparkle, and everyone would have to download a new build by hand once.

## Why ad-hoc signed builds can update each other

Release builds come from CI, which has no signing identity, so they are
ad-hoc signed and not notarized. An ad-hoc signature's designated requirement
is the build's own hash, so no two builds ever "match" in the code signing
sense.

Sparkle 2 still accepts these updates, and this was tested end to end. In
`SUUpdateValidator.m` an app bundle update passes if either the EdDSA
signature checks out against the old app's `SUPublicEDKey`, or the new app's
code signature matches the old one. EdDSA passes here. Sparkle then also
requires the new app's own code signature to be valid, which is why
`build.sh` signs Sparkle's helpers, then the framework, then the app, inside
out. A broken signature anywhere in the bundle would make every update fail.

Sparkle removes the quarantine flag from what it installs, so an update does
not trigger Gatekeeper the way a first download does.
