# macOS release and update delivery

AkiTTY uses its own `akitty-releases` R2 bucket and `akitty-downloads` Worker at
`https://download.automatosx.com/akitty/`. The existing AX Code domain and other
product routes remain independently owned. No DNS changes are required.

This follows lessons from AX Code and AX Code Desktop: capture exact artifact
bytes, refuse changes to versioned objects, verify storage and anonymous downloads,
then publish readiness and mutable discovery pointers. The signed Sparkle feed is
published last. Errors fail publication rather than advertising an incomplete update.

The app uses Sparkle 2.10.1 with an embedded Ed25519 public key. Both update archives
and the feed are signed, and archives are verified before extraction. The private
update key stays in the macOS Keychain under the `akitty` account. Apple signing and
notarization use the separately configured Developer ID and notarytool profile.
Credentials, receipts and private deployment notes never belong in Git.

## Release sequence

1. Update the workspace/package versions, Info.plist marketing/build versions and
   release notes. Build numbers must increase. Commit on a release branch; wait for
   its required macOS verification before advancing protected `main` to that commit.
2. Run `scripts/verify.sh`, then `scripts/build-app.sh release` from that clean commit.
3. Run `scripts/notarize.sh` with `AKITTY_SIGNING_IDENTITY` and
   `AKITTY_NOTARY_PROFILE` set. Verify the actual app and its extracted ZIP.
4. Run `python3 scripts/prepare-release.py`. It snapshots the notarized ZIP,
   validates its identity, source build stamp and signature, generates a signed appcast, and records
   the source SHA, archive size and SHA-256. Output is `build/release/vX.Y.Z/`.
5. Tag that exact commit. Publish the four prepared assets (ZIP, SHA256SUMS,
   release.json and appcast.xml) on the corresponding GitHub release.
6. For the first deployment or after changing `distribution/worker.mjs`, run `python3 scripts/r2-release.py gateway-deploy`.
   This creates only AkiTTY's isolated bucket, Worker and route, after ownership checks.
7. Run `python3 scripts/r2-release.py publish --tag vX.Y.Z --source build/release/vX.Y.Z`.
   It checks GitHub's published digest metadata before reading the Cloudflare token,
   and also publishes `scripts/install.sh` at the mutable `install` key so the curl
   installer always serves the committed copy.
8. Read back the mutable installer and compare it with the committed file:
   `curl -fsS https://download.automatosx.com/akitty/install | cmp - scripts/install.sh`
   plus a `Cache-Control: no-store` header check. Immutability gates do not cover
   mutable keys, so repeat this readback whenever `scripts/install.sh` changes.
   The installer trusts `latest.json` only to name a version; the archive digest
   comes from the immutable release manifest, so tampering with the mutable tier can
   at worst roll an install back to an older signed release.
9. Independently download the public ZIP, compare SHA-256, extract it, and verify
   Gatekeeper, the app version, and the updater feed. Test both current-version
   checks and an older test copy upgrading to the release.

Run one publisher at a time. The REST upload endpoint does not enforce conditional
writes; existing-object checks and readback verification do not provide a distributed lock.

Cloudflare authentication reads `CLOUDFLARE_API_TOKEN` or the single raw token in
`~/.cf`; the file is not sourced as shell code, copied into the repository, or logged.
The gateway is read-only and permits only public release keys. Versioned downloads
are immutable; `latest.json` and `appcast.xml` use `Cache-Control: no-store`.

There is no automatic terminal restart or background installation. Background checks
show a titlebar reminder while a terminal window is open. Choosing it opens Sparkle's
review/install UI. Existing live-session confirmation still applies before termination.

References: [Sparkle setup](https://sparkle-project.org/documentation/),
[gentle reminders](https://sparkle-project.org/documentation/gentle-reminders/),
[Cloudflare R2 API](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/).
