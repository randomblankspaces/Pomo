# publish/

Everything to do with shipping a Pomo build.

| File | What it is |
|---|---|
| `Pomo-1.0.dmg` | Installer — open, drag Pomo to Applications |
| `Pomo-1.0.zip` | Same app, zipped |
| `SHA256SUMS.txt` | Checksums for both |
| `INSTALL.md` | End-user install steps, including the Gatekeeper bypass |
| `make-release.sh` | Rebuilds all of the above from source |

## Rebuilding

```bash
./publish/make-release.sh 1.0
```

Pass a different version to change the filenames. The script builds Release,
verifies the signature, refuses to package if anything personal or any video
file ended up in the bundle, then writes the zip, the dmg, and the checksums.

## Release checklist

What was checked before tagging 1.0. Worth re-running for any later version —
the first four are automated inside `make-release.sh`.

- [x] Release build succeeds from a **clean clone** with only the team ID substituted
- [x] Signature valid, and carries **no developer identity** (would leak an Apple ID email)
- [x] No `.mp4` / `.mov` / `.m4v` or user data inside the bundle
- [x] Checksums recorded and verified against the files on disk
- [x] DMG mounts, app launches from it, widget extension embedded
- [x] Zip round-trip preserves the code signature
- [x] Quarantine genuinely blocks the app, and the documented `xattr` fix genuinely clears it
- [x] App ↔ widget shared state verified across two processes, and confirmed
      present in the **shipped** artifact rather than only in source
- [x] No secrets, absolute home paths, or personal identifiers in tracked source
- [x] `YOUR_TEAM_ID` placeholders still in place, so nobody inherits a real team

Known and accepted for this release:

- The app is **not notarized** — see below. Users clear quarantine once.
- Two built-in themes are named after existing works (*Initial D*, and *Boreal
  Valley* from Dark Souls III), and the screenshots show that footage. Fine for
  a hobby project; rename them if the repo ever wants a cleaner footing.

## Why the app is ad-hoc signed

Distributing a signed, notarized macOS app needs a paid Apple Developer
Program membership ($99/yr) to get a **Developer ID Application** certificate.
Without one there are two options, and neither is notarization:

- **Ad-hoc** (`codesign -s -`) — what this uses. No developer identity is
  embedded, so nothing personal ships in the binary.
- **Apple Development certificate** — rejected here on purpose. That
  certificate embeds the developer's Apple ID email in the signature, and it
  isn't valid for distribution anyway: other people's Macs won't trust it.

The tradeoff is that users hit a Gatekeeper warning on first launch and have
to clear the quarantine flag once. `INSTALL.md` walks through it.

`make-release.sh` will abort rather than package a build whose signature
carries a developer identity, so this can't regress by accident.

## If you get a paid developer account later

Sign and notarize instead, and the first-launch warning disappears:

```bash
# Sign with Developer ID and a hardened runtime
codesign --force --deep --options runtime --timestamp \
    --sign "Developer ID Application: YOUR NAME (TEAMID)" Pomo.app

# Notarize and staple
xcrun notarytool submit Pomo-1.0.zip \
    --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD \
    --wait
xcrun stapler staple Pomo.app
```

Rebuild the zip and dmg from the stapled app afterwards.

## A note on shipping binaries in git

These artifacts are committed to the repo. GitHub's usual home for release
binaries is the **Releases** page, which keeps clones small and gives you
download counts — worth switching to if the repo grows or versions pile up.
Attach the same `.dmg` and `.zip` there and the workflow is otherwise
identical.
