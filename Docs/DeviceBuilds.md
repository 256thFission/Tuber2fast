# Getting builds onto iPads

Push a branch, and about five minutes later the build is on your iPad. No Mac,
no Xcode, no certificates on your machine.

This is the setup guide. Most of it is done **once, by one person**. If the
pipeline already works and you are a contributor, you only need
[Part 5](#part-5--each-contributor).

## How it works

`.github/workflows/device.yml` runs on every push. It builds and tests against
the pinned simulator, and only if that passes does it archive, sign an ad hoc
build, and hand it to Firebase App Distribution, which notifies the registered
iPads.

Ad hoc rather than TestFlight because Apple processes every TestFlight upload —
five to thirty minutes, outside our control. An ad hoc build is signed against a
profile that already names each iPad by UDID, so nothing of Apple's sits between
the export and the install, and there is no trust prompt on the device.

An ad hoc build needs **no device restart and no trust step**. 

## Who does what

| Part | Who | When |
|---|---|---|
| 1. Firebase project | Whoever administers the repo | Once |
| 2. Apple certificate, devices, profile | The Apple Developer **account holder or an admin** | Once, plus when a device is added |
| 3. Export signing assets | Same person, on a Mac | Once |
| 4. GitHub secrets | Whoever administers the repo | Once |
| 5. Register your iPad | Every contributor | Once each |

---

## Part 1 — Firebase project

Firebase hosts the `.ipa`, sends the notifications, and — most usefully —
collects contributors' UDIDs so nobody needs a Mac to find their own.

1. Create a project at <https://console.firebase.google.com>. Analytics is not
   needed.
2. Add an **iOS app**. The bundle ID must match what CI builds; use
   `com.tubernotes.greenfield` unless you have decided otherwise. Skip the
   `GoogleService-Info.plist` download — this app does not embed the SDK.
3. Copy the **App ID** (looks like `1:123456789:ios:abc123`). That becomes the
   `FIREBASE_APP_ID` secret.
4. Under **App Distribution → Testers & Groups**, create a group named exactly
   `devices`. The workflow distributes to that name.
5. Add each contributor's email to the group.
6. Create a service account for CI: **Project settings → Service accounts →
   Generate new private key**. Grant it the *Firebase App Distribution Admin*
   role. The downloaded JSON becomes the `FIREBASE_SERVICE_ACCOUNT` secret.

Contributors will get an invitation email. It produces the UDIDs Part 2 needs.

---

## Part 2 — Apple Developer portal

At <https://developer.apple.com/account>, signed in as the account holder.

**Register the App ID.** Identifiers → **+** → App IDs → App. Use an explicit
bundle ID matching Firebase. No capabilities are required.

**Register every iPad.** Devices → **+**. You need each device's UDID, which
Part 5 collects through Firebase. You may register up to 100 devices per device
type per membership year, and removing one does not free the slot until the year
rolls over — so do not register devices casually.

**Create the distribution certificate.** Certificates → **+** → *Apple
Distribution*. It asks for a Certificate Signing Request:

```bash
# On a Mac: Keychain Access → Certificate Assistant →
#   Request a Certificate From a Certificate Authority
#   • enter your email, leave CA Email blank
#   • choose "Saved to disk"
```

Upload the CSR, download the resulting `.cer`, and double-click it to add it to
the keychain of the Mac that made the request. The private key lives only on
that Mac — this matters for Part 3.

**Create the ad hoc profile.** Profiles → **+** → Distribution → **Ad Hoc**.
Select the App ID, the distribution certificate, and **all** registered devices.
Name it something you will recognise, download the `.mobileprovision`.

> Adding a contributor later means editing this profile to include their device,
> downloading it again, and updating the `ADHOC_PROFILE_BASE64` secret. Nothing
> else changes — the workflow reads the profile's name from the file itself.

---

## Part 3 — Export the signing assets

On the Mac whose keychain holds the private key.

```bash
# Keychain Access → My Certificates → right-click the
# "Apple Distribution: ..." identity → Export → .p12 → set a password.
# Keep that password; it becomes DIST_CERT_P12_PASSWORD.
```

Export the identity, **not** just the certificate — the export must include the
private key. If the row does not expand to show a key, you are on the wrong Mac.

Then base64-encode both files:

```bash
base64 -i TuberNotesDist.p12       > dist-cert.b64
base64 -i TuberNotes_AdHoc.mobileprovision > adhoc-profile.b64
```

---

## Part 4 — GitHub secrets

From a clone of the repo, with the [`gh` CLI](https://cli.github.com)
authenticated:

```bash
gh secret   set DIST_CERT_P12_BASE64    < dist-cert.b64
gh secret   set ADHOC_PROFILE_BASE64    < adhoc-profile.b64
gh secret   set DIST_CERT_P12_PASSWORD  --body 'the .p12 password'
gh secret   set APPLE_TEAM_ID           --body 'YOURTEAMID'
gh secret   set FIREBASE_APP_ID         --body '1:123456789:ios:abc123'
gh secret   set FIREBASE_SERVICE_ACCOUNT < service-account.json

gh variable set CANONICAL_BUNDLE_ID     --body 'com.tubernotes.greenfield'
```

The bundle ID is a variable rather than a secret because it is not sensitive and
it is useful to read in logs.

Then delete the local copies — `dist-cert.b64` and the `.p12` are the signing
identity itself:

```bash
rm -f dist-cert.b64 adhoc-profile.b64 TuberNotesDist.p12 service-account.json
```

Before the first real run, pin the Firebase action in `device.yml` to a commit
SHA rather than `@v1`. It is third-party code that receives the service account
credentials, and a tag can be moved to point at different code.

---

## Part 5 — Each contributor

You need an iPad and the invitation email. Nothing else.

1. Open the Firebase App Distribution invite **on the iPad**, in Safari.
2. Accept, and follow the prompt to **register your device**. This installs a
   short-lived profile so Firebase can read your UDID, then you can delete it.
3. Tell whoever owns Part 2 that you have registered. Your UDID appears in the
   Firebase console; they add it to the ad hoc profile.
4. Once the profile has been updated and one new build has run, installs work.

After that: push a branch, wait for the notification, tap install. If the app is
already installed, the new build replaces it.

**Your local builds are separate.** If you also build from your own Mac, set a
different `TN_BUNDLE_ID_PREFIX` in your `Local.xcconfig` — for example
`com.tubernotes.greenfield.dev`. Otherwise the CI build and your own build share
an identifier and overwrite each other on the iPad.

---

