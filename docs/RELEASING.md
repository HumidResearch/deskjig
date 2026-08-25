# Releasing DeskJig

DeskJig ships as a notarized DMG attached to a GitHub Release, with a Sparkle
appcast published alongside it so installed copies update themselves.

Everything is driven by one thing: **pushing a `v*` tag**.
`.github/workflows/release.yml` does the rest — build, sign, notarize, staple,
package, sign the update, regenerate the feed, publish.

> **Verification host.** All release verification (installing the DMG, launching
> the app, watching an auto-update land) happens on the **Mac Studio**. The Mac
> Mini is not used in this effort.

---

## Part 1 — One-time setup

You run every command in this part yourself. Nothing here is automatable and no
private key material should ever pass through an agent, a chat window, or a
commit. Do the four sections in order; section 4 depends on 1–3.

### 1. Developer ID Application certificate

Signing identity comes from your personal Apple Developer account.

1. In Xcode: **Settings → Accounts**, sign in with the Apple ID that holds the
   Apple Developer Program membership, select the team, **Manage Certificates…**,
   then **+ → Developer ID Application**. (Equivalently: create a CSR in
   Keychain Access and upload it at
   <https://developer.apple.com/account/resources/certificates/list>.)
2. In **Keychain Access → login → My Certificates**, find
   `Developer ID Application: <Your Name> (TEAMID)`. Confirm it has a private key
   (a disclosure triangle).
3. Right-click it → **Export "Developer ID Application: …"** → format
   **Personal Information Exchange (.p12)** → save as `DeveloperID.p12`.
   **Set a strong password** — the export password is what
   `MACOS_CERTIFICATE_PASSWORD` holds.
4. Sanity-check locally:

   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

   Note the Team ID in parentheses; the workflow parses it out of the identity
   name automatically, so you do not need to store it as a secret.

### 2. App Store Connect API key (for `notarytool`)

An API key is used instead of an app-specific password: it does not expire on
password rotation and carries no Apple ID session.

1. Go to <https://appstoreconnect.apple.com/access/integrations/api> → **Team
   Keys** → **+**.
2. Name it something like `deskjig-notary`, access role **Developer** (sufficient
   for notarization), then **Generate**.
3. Download `AuthKey_<KEYID>.p8`. **Apple lets you download it exactly once.**
   Store it in your password manager.
4. From the same page note:
   - **Key ID** — the `<KEYID>` in the filename → `NOTARY_KEY_ID`
   - **Issuer ID** — the UUID shown above the key list → `NOTARY_ISSUER_ID`

### 3. Sparkle EdDSA keypair

Sparkle verifies every downloaded update against a public key baked into the app.
Generate the pair with the `generate_keys` binary that ships inside Sparkle's
SwiftPM artifact — it is already on disk after any build:

```bash
bun run build:app -- --no-signing        # if you have not built yet
find build/DerivedData/SourcePackages/artifacts -name generate_keys -type f
```

Then run it:

```bash
./build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

It stores the **private** key in your login keychain and prints the **public**
key. To also get the private key as a string for the CI secret:

```bash
./build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key.txt
```

Now:

1. Copy the printed `SUPublicEDKey` value into `DeskJig/Info.plist`, replacing
   the literal `REPLACE_WITH_SPARKLE_PUBLIC_KEY`. Commit it — the public key is
   meant to be public, and the release workflow refuses to build while the
   placeholder is still there.
2. Keep `sparkle_private_key.txt` for step 4, then **delete it from disk** and
   keep the only copy in your password manager plus the login keychain.

> Losing the private key means no existing install can ever be updated again —
> a new key would fail signature verification on every machine already running
> DeskJig. Back it up.

### 4. Push the secrets to GitHub

Run these yourself, from the repo root, with `gh` authenticated as `armynante`.
The values never leave your machine except as GitHub secrets.

```bash
# 1. Developer ID certificate, base64-encoded
gh secret set MACOS_CERTIFICATE_P12 -R armynante/deskjig \
  --body "$(base64 -i /path/to/DeveloperID.p12)"

# 2. The password you exported the .p12 with (prompts, nothing in shell history)
gh secret set MACOS_CERTIFICATE_PASSWORD -R armynante/deskjig

# 3-4. App Store Connect key identifiers (prompts)
gh secret set NOTARY_KEY_ID    -R armynante/deskjig
gh secret set NOTARY_ISSUER_ID -R armynante/deskjig

# 5. The .p8 private key, base64-encoded
gh secret set NOTARY_KEY_P8 -R armynante/deskjig \
  --body "$(base64 -i /path/to/AuthKey_XXXXXXXXXX.p8)"

# 6. Sparkle EdDSA private key (the string generate_keys -x wrote)
gh secret set SPARKLE_PRIVATE_KEY -R armynante/deskjig \
  --body "$(cat sparkle_private_key.txt)"

# Confirm all six are present
gh secret list -R armynante/deskjig
```

| Secret | Contents |
|---|---|
| `MACOS_CERTIFICATE_P12` | base64 of the Developer ID Application `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `NOTARY_KEY_ID` | App Store Connect API Key ID |
| `NOTARY_ISSUER_ID` | App Store Connect API Issuer UUID |
| `NOTARY_KEY_P8` | base64 of `AuthKey_<KEYID>.p8` |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA private key string |

Then shred the local copies:

```bash
rm -P /path/to/DeveloperID.p12 sparkle_private_key.txt
```

---

## Part 2 — Cutting a release

### 1. Bump the version

`Version.xcconfig` at the repo root is the single source of truth. Both the app
and the `deskjig` CLI read it, so there is exactly one file to edit:

```
MARKETING_VERSION = 1.0.1        # user-visible; must equal the tag minus its "v"
CURRENT_PROJECT_VERSION = 2      # plain integer; MUST strictly increase
```

Two rules the workflow enforces for you:

- `MARKETING_VERSION` must match the tag (`v1.0.1` → `1.0.1`), or the run fails
  before anything is built.
- `CURRENT_PROJECT_VERSION` must be greater than the highest already in the
  published appcast. Sparkle compares `CFBundleVersion`, so a stale build number
  produces a release that silently never installs over its predecessor. The
  appcast generator fails the run rather than publish one.

### 2. Optional release notes

If `release_notes/v<version>.md` exists it becomes both the GitHub Release body
and the Sparkle item `<description>` shown in the update dialog. Without it the
release body is auto-generated from commits and the Sparkle description is a
one-liner linking to the release page.

### 3. Commit, tag, push

```bash
git switch -c release/v1.0.1
# edit Version.xcconfig (and release_notes/v1.0.1.md if you want notes)
git commit -am "release: 1.0.1"
# open a PR and merge it — main is the branch releases are cut from
```

Once the bump is on `main`:

```bash
git switch main && git pull
git tag v1.0.1
git push origin v1.0.1
```

Pushing the tag is what starts the release. Watch it:

```bash
gh run watch -R armynante/deskjig
```

Roughly 20–40 minutes, most of it two notarization round trips.

### 4. Verify (on the Mac Studio)

```bash
# Download what was actually published
gh release download v1.0.1 -R armynante/deskjig -p '*.dmg' -D ~/Downloads

# Gatekeeper, offline — this is what a user's Mac does
spctl -a -vv -t open --context context:primary-signature ~/Downloads/DeskJig-1.0.1.dmg
hdiutil attach ~/Downloads/DeskJig-1.0.1.dmg
spctl -a -vv /Volumes/DeskJig\ 1.0.1/DeskJig.app
codesign -dv --verbose=4 /Volumes/DeskJig\ 1.0.1/DeskJig.app

# Install and check both version surfaces agree
cp -R /Volumes/DeskJig\ 1.0.1/DeskJig.app /Applications/
hdiutil detach /Volumes/DeskJig\ 1.0.1
/Applications/DeskJig.app/Contents/Helpers/deskjig --version    # -> 1.0.1

# The feed the app actually reads
curl -fsSL https://github.com/armynante/deskjig/releases/latest/download/appcast.xml
```

**Auto-update proof** (do this once, when the second release exists): install the
older DMG, launch it, and use **Settings → Check for Updates**. Sparkle should
find the newer version, download it, verify the EdDSA signature, and relaunch
into the new build. If it finds nothing, the cause is almost always a
`CURRENT_PROJECT_VERSION` that did not increase.

---

## How the pieces fit

### The appcast is served from `/releases/latest/download/`

`SUFeedURL` in `DeskJig/Info.plist` is:

```
https://github.com/armynante/deskjig/releases/latest/download/appcast.xml
```

GitHub answers that path with a `302` to the newest **non-prerelease** release's
`appcast.xml` asset, and Sparkle's downloader follows HTTP redirects. Every
release republishes the asset, so the URL above is correct forever without any
hosting beyond GitHub Releases.

The alternative considered was committing `appcast.xml` to a `gh-pages` branch.
It was rejected: it needs GitHub Pages enabled (extra setup, and Pages on a
private repo is a paid feature — this repo is private until the v1.0.0 flip), it
adds a second write target the release workflow must have push rights to, and it
splits the release artifacts across two places. The redirect URL needs none of
that. Its one real constraint is that a **prerelease tag must not become
`latest`** — the workflow passes `--prerelease` to `gh release create` for any
tag with a `-suffix`, which keeps the stable feed pointing at the last stable
release.

### Version numbers

| Where | Value | Source |
|---|---|---|
| `DeskJig.app` `CFBundleShortVersionString` | `1.0.0` | `MARKETING_VERSION` |
| `DeskJig.app` `CFBundleVersion` | `1` | `CURRENT_PROJECT_VERSION` |
| `deskjig --version` | `1.0.0` | `MARKETING_VERSION`, via an Info.plist section linked into the binary |
| appcast `sparkle:shortVersionString` | `1.0.0` | read back off the built app |
| appcast `sparkle:version` | `1` | read back off the built app |

The CLI is a command-line tool with no Info.plist on disk, so
`DeskJigVersion.current` used to fall through to the literal `"unknown"`.
`DeskJigCLI/DeskJigCLI.xcconfig` now sets `GENERATE_INFOPLIST_FILE` and
`CREATE_INFOPLIST_SECTION_IN_BINARY`, which links a plist into
`__TEXT,__info_plist`. That travels with the binary wherever it goes — inside
`DeskJig.app/Contents/Helpers/`, symlinked at `/usr/local/bin/deskjig`, or run
straight out of the build directory.

### Fork safety

The release job carries `if: github.repository == 'armynante/deskjig'`. A fork
that pushes a `v*` tag gets a skipped job, not a run that fails partway through
trying to decrypt a certificate it does not have. Any future job added to this
workflow needs the same guard.

### Signing material handling

Certificate, notary key and Sparkle key are all written under `$RUNNER_TEMP` on
an ephemeral runner, imported into a throwaway keychain whose password is a
freshly generated UUID, and deleted in an `if: always()` cleanup step. Nothing is
written into the workspace, so nothing can be committed or uploaded by accident.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Tag version 'X' does not match MARKETING_VERSION 'Y'` | The version bump was not committed before tagging. Fix `Version.xcconfig` on `main`, delete the tag (`git push --delete origin vX`), re-tag. |
| `Info.plist still carries the SUPublicEDKey placeholder` | Part 1 §3 has not been done. |
| `No 'Developer ID Application' identity found` | The `.p12` was exported without its private key, or a *Development* certificate was exported instead of *Developer ID Application*. |
| `notarytool` returns `Invalid` | Run `xcrun notarytool log <submission-id> --key … --key-id … --issuer …` for the per-file reason. Usually an unsigned or hardened-runtime-less nested binary. |
| Sparkle says "no update available" between two real releases | `CURRENT_PROJECT_VERSION` did not increase. |
| Sparkle downloads then reports a signature failure | `SPARKLE_PRIVATE_KEY` does not match the `SUPublicEDKey` committed in `Info.plist`. |
| Update check does nothing at all, and the log says "placeholder Sparkle configuration" | The installed build predates the real public key. Expected for any build made before Part 1 §3. |
