# Releasing StatBar (zero-cost workflow)

StatBar ships updates two ways:

- **FreeUpdateChecker** (default) — a dependency-free check against a static
  `version.json`. No Apple Developer Program, no notarization, no server. This
  is the workflow documented below.
- **Sparkle** (optional) — flip `Config.Updates.useSparkle = true` once a signed
  + notarized appcast pipeline exists. See `scripts/build_release.sh`,
  `scripts/sign_appcast.sh`, and `appcast.xml`.

The free path costs nothing: build locally, host two static files (the app zip
and `version.json`) on any static host (GitHub Pages, S3, a gist, Netlify…).

---

## 1. Bump the version

Edit `Info.plist`:

- `CFBundleShortVersionString` — the user-facing version (e.g. `1.2.0`). This is
  what `FreeUpdateChecker` compares against the manifest.
- `CFBundleVersion` — the monotonic build number (e.g. `7`).

Use the same `CFBundleShortVersionString` as the `version` you'll put in
`version.json`.

## 2. Build + re-sign + verify + zip

```sh
make beta
```

`make beta`:

1. `scripts/build_local.sh` — assembles `build/StatBar.app` and ad-hoc re-signs
   it (launchable on Apple Silicon).
2. `codesign --verify --deep --strict` — hard-verifies the bundle signature;
   any failure aborts before a zip is produced.
3. `scripts/package_beta.sh` — names the archive from the bundle version
   (`build/StatBar-v<short>.zip`, or `-build<build>` when the build number
   differs), archives with `ditto -c -k --keepParent` (preserves
   `Sparkle.framework` symlinks; plain `zip` corrupts them), writes a
   `.sha256` sidecar, and round-trip-verifies the archive re-extracts to a
   valid signed `StatBar.app`.

Output ends with the absolute zip path, size, and SHA-256. Older
`StatBar-v*.zip` betas are pruned so only the current version remains.

## 3. Update `version.json`

Create/update the manifest served at `Config.Updates.versionManifestURL`
(default `https://getstatbar.com/version.json`):

```json
{
  "version": "1.2.0",
  "downloadURL": "https://getstatbar.com/download/StatBar.app.zip",
  "releaseNotes": "• Fixed NHL scores\n• Faster launch",
  "minimumSupported": "1.1.0",
  "publishedAt": "2026-06-17T12:00:00Z"
}
```

Fields:

| Field              | Required | Meaning                                                        |
| ------------------ | -------- | -------------------------------------------------------------- |
| `version`          | yes      | Latest released version. Compared numerically (`1.10 > 1.9`).  |
| `downloadURL`      | no       | Where "Download Update" sends the browser. Omit → button off.  |
| `releaseNotes`     | no       | Shown in the alert. `\n` for line breaks.                      |
| `minimumSupported` | no       | If installed version is older, the update is flagged required. |
| `publishedAt`      | no       | ISO-8601 timestamp, shown in the alert.                        |

`version` must match the `CFBundleShortVersionString` from step 1.

## 4. Upload + push to hosting

Upload two files to the static host:

- `build/StatBar-v<version>.zip` (from `make beta`) → the `downloadURL` above.
- `version.json` → `Config.Updates.versionManifestURL`.

For GitHub Pages:

```sh
# from the gh-pages branch / docs site repo
cp ../statbar/build/StatBar-v1.2.0.zip download/StatBar.app.zip
cp ../statbar/version.json version.json
git add download/StatBar.app.zip version.json
git commit -m "Release 1.2.0"
git push
```

The hosted name can be whatever your `downloadURL` points at (e.g. a stable
`StatBar.app.zip`); just keep `downloadURL` and the uploaded file in sync.

Make sure both URLs are served with the correct content type and are publicly
reachable (no auth wall) — the in-app checker fetches them with no credentials.

## 5. Verify the in-app update check

1. Launch a build whose `CFBundleShortVersionString` is **older** than the
   manifest `version`.
2. Open **Settings → General → Check for Updates…**.
3. Confirm the alert shows current + latest version, release notes, and
   **Download Update** opens `downloadURL` in the default browser.
4. Tap the **Version** row 5× to reveal **Debug Information** and confirm:
   - **Update channel** = `FreeUpdateChecker`
   - **Update URL** = your `version.json`
   - **Last update check** / **Last update result** are populated.
5. Re-run on a build at the latest version → "You're up to date".
6. Offline check (turn off Wi-Fi) → graceful "Couldn't check for updates", no
   crash, reason logged under subsystem `com.getstatbar.StatBar` / category
   `updates` (Console.app).

---

## Notes

- `version.json` is independent of Sparkle's `appcast.xml`; you can host both.
- No code signing identity is required for the free path — ad-hoc signing is
  enough for users who download manually (they right-click → Open the first
  time, or you ship instructions).
- To later switch to Sparkle auto-updates, set `Config.Updates.useSparkle =
  true` and follow the Developer ID + notarization path in
  `scripts/build_release.sh`.
