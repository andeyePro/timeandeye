# Entitled build – Developer ID + CloudKit + notarisation, no Xcode project

How to take the current CLT-only SwiftPM build (`scripts/make-app.sh`, ad-hoc /
self-signed) to a Developer ID signed, CloudKit-entitled, notarised
`andeye.app` – **without converting the Mac app to an Xcode project**. The
short answer up front: the whole Mac pipeline stays `swift build` + `codesign`
+ `notarytool`; the only things that genuinely need Apple's GUI surfaces are
one-time portal/console clicks, and the only place a real `.xcodeproj` is
unavoidable is the planned iOS companion (already scoped that way in TODO.md).

Bundle ID everywhere below: `com.andeye.mac` (already in make-app.sh).
Container ID: `iCloud.com.andeye.mac`. `TEAMID` means the 10-character
Team ID from https://developer.apple.com/account → Membership details.

---

## 0. Why each piece is needed

- **Developer ID Application certificate** – Gatekeeper-trusted signing for
  direct (non-App-Store) distribution. The Mac App Store is off the table
  anyway (Accessibility + Apple Events are sandbox-incompatible; see the
  design spec), so Developer ID is the only distribution-grade identity.
- **iCloud/CloudKit entitlements** – `CloudKitSyncTransport` is deliberately
  inert today because the ad-hoc build has no entitlement. iCloud entitlements
  are *restricted*: the OS only honours them when a provisioning profile that
  grants them is embedded in the app. Apple has allowed CloudKit (and push)
  in Developer ID apps since 2016; it works, but only against the
  **Production** CloudKit environment.
- **Provisioning profile (`embedded.provisionprofile`)** – the signed
  permission slip tying TEAMID + bundle ID + restricted entitlements
  together. Without it, an app signed with iCloud entitlements is **killed by
  AMFI/taskgated at launch** (looks like an instant crash; Console shows a
  provisioning/entitlement denial). This is the piece App Store apps get
  invisibly from Xcode; direct-distribution apps embed it by hand.
- **Notarisation** – Gatekeeper on current macOS effectively requires it for
  downloaded apps. Needs hardened runtime + secure timestamp at signing time.

---

## 1. One-time portal work (Martin, in the browser – scripts cannot do these)

All at https://developer.apple.com/account unless noted. Order matters.

1. **Enrol in the Apple Developer Program** (US$99/yr) if not already. The
   free tier gives neither Developer ID certificates nor CloudKit.
2. **Create the Developer ID Application certificate**
   (Certificates → “+” → Developer ID Application).
   Only the **Account Holder** role can create Developer ID certs.
   You need a CSR first – make it on the Mac without any GUI if you like:

   ```bash
   openssl req -new -newkey rsa:2048 -nodes \
     -keyout devid.key -out devid.csr \
     -subj "/emailAddress=martin@example.com/CN=Martin Currie/C=GB"
   ```

   Upload `devid.csr`, download `developerID_application.cer`, then import
   both halves into the login keychain:

   ```bash
   security import devid.key -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
   security import developerID_application.cer -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
   ```

   Verify: `security find-identity -v -p codesigning` should list
   `Developer ID Application: <name> (TEAMID)`.
   (Alternative: Keychain Access → Certificate Assistant → Request a
   Certificate… does the CSR + key in one step.)
   Also download Apple's **Developer ID G2 intermediate** if the identity
   shows as “not trusted” – https://www.apple.com/certificateauthority/.
3. **Register the App ID** (Identifiers → “+” → App IDs → App):
   explicit bundle ID `com.andeye.mac`; tick capabilities **iCloud**
   (with CloudKit support) and **Push Notifications** (push is how CloudKit
   zone subscriptions wake the app – wanted for sync, harmless if unused).
4. **Create the iCloud container** (Identifiers → dropdown “iCloud
   Containers” → “+”): `iCloud.com.andeye.mac`. Then edit the App ID's
   iCloud capability and **assign** this container to it.
5. **Create the Developer ID provisioning profile**
   (Profiles → “+” → Distribution → **Developer ID**): select the App ID from
   step 3 and the certificate from step 2. Download it; it lands as
   `andeye_Developer_ID.provisionprofile` (any name is fine). Check the
   repo out: this file is not secret (it contains no private key) but it is
   per-team – keep it out of the public repo, park it next to the pro repo's
   secrets. Profile lifetime is tied to the certificate (Developer ID certs
   run up to 5 years); regenerate the profile when the cert rolls.
6. **CloudKit schema** (https://icloud.developer.apple.com – CloudKit
   Console): Developer ID apps run against **Production**, and Production
   does **not** allow just-in-time schema creation, so `SessionRevision`
   must exist before the first real sync. Two Xcode-free routes:
   - **Console-only (recommended):** in the *Development* environment create
     record type `SessionRevision` with fields `json` (Bytes), `hlcMillis`
     (Int64), `hlcCounter` (Int64), `hlcDevice` (String), `origin` (Int64),
     `deleted` (Int64) – matching `CloudKitSyncTransport.record(from:)`.
     No queryable indexes needed (`recordZoneChanges` reads by zone, not by
     query). Then **Deploy Schema Changes… → Production**. The custom zone
     `AndeyeJournal` needs no pre-creation; zones are data, not schema.
   - Or run a Development-signed build once so CloudKit JIT-creates the
     types, then deploy. Skip this: it needs an Apple Development cert, a
     registered Mac (Provisioning UDID) and a Mac Development profile – three
     extra artefacts for zero benefit over typing six fields into the console.
7. **Notary credentials** – either an app-specific password
   (https://account.apple.com → Sign-In and Security → App-Specific
   Passwords) or, nicer for automation, an **App Store Connect API key**
   (App Store Connect → Users and Access → Integrations → Keys, role
   Developer). Store it once on the build Mac:

   ```bash
   xcrun notarytool store-credentials andeye-notary \
     --apple-id martin@example.com --team-id TEAMID \
     --password <app-specific-password>
   ```

   After this, no secret ever appears in scripts – they say
   `--keychain-profile andeye-notary`.

Everything after this heading is scriptable.

---

## 2. The entitlements plist

`scripts/andeye.entitlements` (checked in – nothing secret):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Restricted entitlements: must all be authorised by
         embedded.provisionprofile or the app is killed at launch. -->
    <key>com.apple.application-identifier</key>
    <string>TEAMID.com.andeye.mac</string>
    <key>com.apple.developer.team-identifier</key>
    <string>TEAMID</string>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array><string>iCloud.com.andeye.mac</string></array>
    <key>com.apple.developer.icloud-services</key>
    <array><string>CloudKit</string></array>
    <!-- Developer ID profiles only ever authorise Production. -->
    <key>com.apple.developer.icloud-container-environment</key>
    <string>Production</string>
    <!-- CloudKit zone-subscription wakeups. macOS key (note the prefix -
         iOS uses bare "aps-environment"); Developer ID ⇒ production. -->
    <key>com.apple.developer.aps-environment</key>
    <string>production</string>

    <!-- Hardened-runtime exception: sending Apple Events (browser tab URLs).
         Without this the hardened runtime silently refuses to send and tab
         attribution dies. TCC still prompts per-target-app as today. -->
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
```

Substitute the real TEAMID (a script can pull it out of the profile itself:
`security cms -D -i andeye.provisionprofile | plutil -extract TeamIdentifier.0 raw -`).

Deliberately **not** included:

- `com.apple.security.device.audio-input` – the mic sensor only reads
  `kAudioDevicePropertyDeviceIsRunningSomewhere` (Sensors.swift), it never
  opens an input stream, so the hardened-runtime capture exception isn't
  needed. Add it (and keep the Info.plist usage string) only if a future
  sensor actually captures audio.
- App Sandbox – off, permanently: Accessibility window titles are
  sandbox-incompatible.
- `com.apple.security.get-task-allow` – debug-only; notarisation rejects it.
  `swift build -c release` doesn't add it; just never sign with a debug
  entitlements file.

Accessibility has no entitlement at all – it stays pure TCC, same as today.

---

## 3. How the signed SPM bundle goes together

`codesign --entitlements` works on any bundle – it neither knows nor cares
that Xcode didn't build it. The entitlements blob is baked into the code
signature of the main executable; the provisioning profile is just a file at
a well-known path that must be present **before** signing (it's covered by
the bundle's resource seal, so adding it later breaks the signature).

Order of operations, replacing the self-signed block of make-app.sh (keep the
build/Info.plist/stamp parts unchanged):

```bash
IDENTITY="Developer ID Application: Martin Currie (TEAMID)"
PROFILE="$HOME/secrets/andeye_Developer_ID.provisionprofile"

# 1. Embed the profile - BEFORE signing, exact filename matters.
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

# 2. Sign: hardened runtime + secure timestamp are notarisation requirements.
#    Single Mach-O, no nested frameworks yet, so one codesign call suffices;
#    when Sparkle arrives, nested code signs first (see §6).
codesign --force --options runtime --timestamp \
    --entitlements scripts/andeye.entitlements \
    --sign "$IDENTITY" "$APP"

# 3. Verify locally before wasting a notarisation round-trip.
codesign --verify --strict --deep -v "$APP"
codesign -d --entitlements - "$APP"          # eyeball the entitlements landed
syspolicy_check distribution "$APP"          # macOS 14+ notarisation pre-flight
```

Gotchas specific to this repo:

- **TCC reset, once.** The whole point of the self-signed “andeye Dev”
  identity was stable TCC grants. Developer ID changes the designated
  requirement again, so Accessibility + Automation grants reset **one final
  time** on the first Developer ID build – and then never again, on any
  machine. The make-app.sh keychain/self-signed machinery
  (`ensure_identity`, `~/ambitick-dev.keychain-db`) becomes dead code for
  release builds; keep it as the no-Apple-account dev fallback path.
- The launch-kill failure mode: if entitlements and profile disagree (wrong
  TEAMID, container not assigned to the App ID, profile missing), the app
  dies instantly at launch. Diagnose with
  `log show --last 2m --predicate 'process == "taskgated-helper" || subsystem == "com.apple.amfi"'`
  and cross-check profile vs plist:
  `security cms -D -i "$APP/Contents/embedded.provisionprofile"`.
- CloudKit at runtime needs the *user* signed into iCloud (System Settings →
  Apple ID). `CKContainer.default()` resolves via the entitlement to
  `iCloud.com.andeye.mac` – no code change needed to adopt the container.
- Push registration for zone subscriptions is
  `NSApplication.registerForRemoteNotifications()` – works fine for an
  `LSUIElement` menu-bar app; silent CloudKit pushes need no user-visible
  notification permission.

---

## 4. Notarisation

```bash
# Zip preserving the bundle (ditto, not zip - resource forks/symlinks).
ditto -c -k --keepParent "$APP" /tmp/andeye.zip

# Submit and block until the verdict (usually 1-5 min).
xcrun notarytool submit /tmp/andeye.zip \
    --keychain-profile andeye-notary --wait

# Staple the ticket to the .app (offline Gatekeeper pass), then re-zip
# for distribution - the stapled bundle, not the submitted zip.
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" andeye-0.1.0.zip

# Final check - exactly what a downloader's Gatekeeper will conclude.
spctl -a -vv "$APP"     # want: "accepted ... source=Notarized Developer ID"
```

On failure: `xcrun notarytool log <submission-id> --keychain-profile
andeye-notary` names every offending binary. The classic causes are a
missing `--options runtime`, missing `--timestamp`, or an unsigned nested
binary. `notarytool` and `stapler` ship with the Command Line Tools – no
Xcode install needed for any of this section.

If distribution moves to a DMG later: sign the DMG
(`codesign -s "$IDENTITY" andeye.dmg`), notarise the DMG (Gatekeeper then
covers both the container and the app inside), staple the DMG *and* the app.

---

## 5. Development iteration against CloudKit

The uncomfortable truth of Developer ID + CloudKit: **there is no Development
environment for release-signed builds**. Practical implications:

- Day-to-day dev builds keep using the existing self-signed path –
  `CloudKitSyncTransport` stays inert there, exactly as its header comment
  says. Sync logic is already tested where it should be: Core's merge is
  pure and covered by `andeyeTTChecks`; CloudKit is a thin pipe.
- To exercise the *pipe* itself, build the entitled flavour (§3) and test
  against Production under a **test iCloud account** (sign the Mac into a
  scratch Apple ID, or use a separate macOS user account signed into one).
  The private-database data lands in the test account's storage, invisible
  to real users – Production-environment testing is normal practice for
  Developer ID CloudKit apps.
- Schema changes repeat portal step 6: edit in Development in the console,
  deploy to Production. Field *additions* are the compatible direction – and
  the transport already ships the whole session as one `json` blob precisely
  so new session fields sync with **zero** CloudKit schema churn. Schema
  edits should be rare.
- If console-clicking schema gets old: `xcrun cktool` can save a management
  token, import a schema file, and deploy to production from a script – but
  cktool ships **inside full Xcode**, not the CLT. Installing Xcode.app for
  its CLI is still not an `.xcodeproj` conversion; weigh it only when schema
  churn actually hurts.

---

## 6. Sparkle compatibility (when auto-update lands)

Nothing above conflicts with Sparkle; notes so the pieces are cut to fit:

- **Dependency without Xcode:** Sparkle 2 distributes as a binary XCFramework
  consumable by SwiftPM (`.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.x.x")`).
  SwiftPM will *link* it but won't assemble an app bundle, so make-app.sh
  grows two steps: copy `Sparkle.framework` into `Contents/Frameworks/`, and
  link the executable with `-Xlinker -rpath -Xlinker @executable_path/../Frameworks`
  (via `unsafeFlags` on the executable target or an extra flag in the build
  invocation) so dyld finds it.
- **Signing order (inside-out):** under hardened runtime + notarisation the
  nested code must be sealed before the outer bundle. Sparkle ships
  pre-signed, but re-sign as your own team, preserving its entitlements
  (Sparkle's XPC services rely on theirs):

  ```bash
  codesign -f -s "$IDENTITY" -o runtime --preserve-metadata=entitlements \
      "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
      "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
      "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
      "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
      "$APP/Contents/Frameworks/Sparkle.framework"
  ```

  Then the main-app codesign from §3 runs last, unchanged. Do **not** use
  `--deep` to sign (fine for *verify*); it stomps nested entitlements.
- **Two unrelated key systems:** Sparkle's appcast is signed with its own
  EdDSA key (`generate_keys`; public half goes in Info.plist as
  `SUPublicEDKey`). This is *not* the Apple identity and *not* the licence
  Ed25519 key in `pro/SIGNING-KEY.txt` – three keys, three jobs; don't reuse.
- **Updates must be notarised too:** Sparkle installs whatever the appcast
  points at, and (by default) validates that the new version's Apple code
  signature matches the running app's Team ID. Every release artefact goes
  through §3-4 – which is fine, because by then it's one script.
- The embedded provisioning profile travels inside the bundle, so
  Sparkle-delivered updates keep their iCloud entitlement with no extra work.

---

## 7. Who does what – the split

**Martin, once, in the portal/console (≈30 min):** enrol; Developer ID
Application cert; App ID `com.andeye.mac` with iCloud + Push; container
`iCloud.com.andeye.mac` assigned to the App ID; Developer ID provisioning
profile downloaded to the build Mac; `SessionRevision` schema created and
deployed to Production in CloudKit Console; notary credentials stored via
`notarytool store-credentials`.

**Martin, per cert roll (every ≤5 years):** new cert, regenerate profile.

**Scripts, every release (extend make-app.sh or add
`scripts/make-release.sh`):** swift build; assemble bundle; stamp version;
copy `embedded.provisionprofile`; codesign with hardened runtime + timestamp
+ entitlements; verify; ditto-zip; `notarytool submit --wait`; staple;
re-zip; `spctl` check. Zero interactive steps once the keychain holds the
identity and the notary profile.

---

## 8. Where a real Xcode project is genuinely unavoidable

- **The iOS companion** – App Store submission needs an Xcode
  archive/export pipeline; already planned as an `ios/` Xcode project
  referencing the local package (TODO.md). The Mac app is untouched by that.
- **Mac App Store distribution** – would need Xcode archive + App Sandbox;
  moot, since Accessibility/Apple Events rule the sandbox out regardless.
- **TestFlight for the Mac beta** – TestFlight on macOS exists only for App
  Store builds, so it's excluded by the same fact. Beta distribution stays
  direct download (and later Sparkle channels), which this pipeline covers.

Not on the list: nothing about Developer ID signing, iCloud entitlements,
provisioning-profile embedding, CloudKit schema, push, notarisation or
Sparkle requires an `.xcodeproj` for the Mac app. The one *Xcode-the-app*
(not project) temptation is `cktool` for scripted schema deploys (§5), and
even that is optional.
