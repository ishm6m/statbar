# Releasing StatBar

StatBar updates through **GitHub Releases**. The app checks a static
`version.json` (via `FreeUpdateChecker`) and points "Download Update" at the
latest release page. No Apple Developer Program, no notarization, no server —
builds are ad-hoc signed, so users right-click → Open the first time.

The two things a release touches:

- the `.zip` attached to the GitHub Release (what users download), and
- `version.json` at the repo root (what the in-app checker reads via raw GitHub).

---

## 1. Bump the version

Edit `Info.plist`:

- `CFBundleShortVersionString` — the user-facing version (e.g. `1.2`). This is
  what `FreeUpdateChecker` compares against the manifest.
- `CFBundleVersion` — the monotonic build number (e.g. `3`).

Keep `CFBundleShortVersionString` equal to the `version` you put in
`version.json` — otherwise a shipped build prompts users to "update" to itself.

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
   differs), archives with `ditto -c -k --keepParent`, writes a `.sha256`
   sidecar, and round-trip-verifies the archive re-extracts to a valid signed
   `StatBar.app`.

Output ends with the absolute zip path, size, and SHA-256.

## 3. Update `version.json`

Edit the manifest at the repo root (served to the app via
`Config.Updates.versionManifestURL`, i.e. raw GitHub on `main`):

```json
{
  "version": "1.2",
  "downloadURL": "https://github.com/ishm6m/statbar/releases/latest",
  "releaseNotes": "• Fixed NHL scores\n• Faster launch",
  "minimumSupported": "1.0",
  "publishedAt": "2026-06-28T12:00:00Z"
}
```

| Field              | Required | Meaning                                                        |
| ------------------ | -------- | -------------------------------------------------------------- |
| `version`          | yes      | Latest released version. Compared numerically (`1.10 > 1.9`).  |
| `downloadURL`      | no       | Where "Download Update" sends the browser. Omit → button off.  |
| `releaseNotes`     | no       | Shown in the alert. `\n` for line breaks.                      |
| `minimumSupported` | no       | If installed version is older, the update is flagged required. |
| `publishedAt`      | no       | ISO-8601 timestamp, shown in the alert.                        |

`version` must match the `CFBundleShortVersionString` from step 1.

## 4. Cut the GitHub Release

Attach the zip under a stable name (`StatBar.app.zip`) so the latest-release
page always offers the same filename, and commit the manifest bump:

```sh
cp build/StatBar-v1.2.zip build/StatBar.app.zip
shasum -a 256 build/StatBar.app.zip > build/StatBar.app.zip.sha256

git add Info.plist version.json
git commit -m "Release 1.2"
git push

gh release create v1.2 \
  build/StatBar.app.zip build/StatBar.app.zip.sha256 \
  --title "v1.2" \
  --notes "• Fixed NHL scores\n• Faster launch"
```

`downloadURL` points at `/releases/latest`, so it resolves to whatever release
is newest — no need to edit it each time.

## 5. Verify the update path

```sh
curl -sI https://github.com/ishm6m/statbar/releases/latest | grep -i location   # → /tag/v1.2
curl -s  https://raw.githubusercontent.com/ishm6m/statbar/main/version.json     # → "version": "1.2"
```

Then in-app:

1. Launch a build whose `CFBundleShortVersionString` is **older** than the
   manifest `version`.
2. **Settings → General → Check for Updates…** — confirm the alert shows current
   + latest version, release notes, and **Download Update** opens the release page.
3. Tap the **Version** row 5× to reveal **Debug Information**; confirm **Update
   URL** is the raw `version.json` and the last-check fields are populated.
4. Re-run on a build at the latest version → "You're up to date".
5. Offline (Wi-Fi off) → graceful "Couldn't check for updates", no crash; reason
   logged under subsystem `com.getstatbar.StatBar` / category `updates`
   (Console.app).
