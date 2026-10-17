# Wordsmith — Sharing It With Friends

> Status: **Plan approved, not yet built.**
>
> **Approach:** no Play Store. The app is shared as a signed **APK** through
> **Firebase App Distribution**. That means no $25 fee and none of the Play
> rules (closed testing, data safety form, store listing).

---

## 1. How friends install and update

1. You add a friend's email to the **"friends" tester group** in Firebase App Distribution.
2. They get an email invite. They accept it, then install the app through the App Tester app or the web link.
3. The first time, Android asks them to **allow installs from this source**. Google Play Protect may warn that the app is from an unknown developer, and they tap **Install anyway**.
4. **Updates:** when a new version is released, App Distribution notifies them and they tap to update.
   - The app also shows its own **"Update available" banner**, using `/v1/version`.
   - Very old versions are blocked from multiplayer until they update.
5. Progress is stored on the server, so updating or reinstalling **never loses anything**.

## 2. Google's developer verification

Google now requires apps on regular Android phones to come from a
**registered developer**, even when they're sideloaded:
- **Brazil, Indonesia, Singapore and Thailand:** in force since **September 30, 2026**.
- **Everywhere else:** from **2027**.

**Our fix (free):** Google's **limited distribution account** for students and
hobbyists. It only needs an email address (no ID), it's free, and it covers
**up to 20 devices**, which is enough for a friend group (co-op is up to 4
players and Versus up to 5). We register Wordsmith's package name and signing
key there.

**Backups** if needed: Android's "advanced" install flow for unregistered apps,
or installing from a computer with ADB.

## 3. Package name and signing

- **Package name:** `com.wordsmithforge.game`.
  - It doesn't need to match a domain we own. It only has to be **unique**, meaning no other app uses it, and it must be accepted when we register it in the limited distribution account.
  - A plain name like `com.wordsmith.game` is probably already taken by one of the existing "Wordsmith" apps, which is why it includes "forge".
  - If registration says it's taken, we choose another **before the first friend build**. After that it can't change without everyone reinstalling.
- **Release signing key:** generated once.
  - It's stored as **GitHub Actions secrets** (the keystore in base64 plus its passwords).
  - Keep a **backup somewhere safe**, such as a password manager.
  - If it's lost, friends have to uninstall and reinstall once. Their progress is safe on the server.
- Its **SHA-1 and SHA-256 fingerprints** get registered in Firebase (Google sign-in needs them) and in the limited distribution account.

## 4. Release pipeline (GitHub Actions)

```
bump `version:` in app/pubspec.yaml, then: git tag v0.3.0 && git push --tags
   └─► .github/workflows/release.yml: tests → build signed release APK
          ├─► upload to Firebase App Distribution → "friends" group notified
          └─► keep the APK as a workflow artifact (30 days)
   (from M2: also deploy the Worker, run D1 migrations, bump /v1/version)
```

**The GitHub repository is public.** That's fine for the code and puzzles,
but the signing key, its passwords and the Firebase service-account key must
only ever live in **GitHub Actions secrets**, never in a commit or an artifact.
The release workflow writes the key to disk only for the build and deletes it
afterwards.

## 5. One-time setup (things only you can do)

Secrets go into GitHub repository settings, **never into chat or a commit**.
The Firebase project already exists: **`wordsmith-8f550`**.

### For the first friend build (now)

1. **Add the Android app to Firebase.**
   - Firebase console → `wordsmith-8f550` → ⚙ **Project settings** → **Your apps** → **Add app** → Android.
   - Package name **`com.wordsmithforge.game`**, nickname "Wordsmith". Leave the SHA field empty for now.
   - Download `google-services.json` when offered and keep it for M2 (sign-in). It isn't needed for the first build.
   - Copy the **App ID** shown under the app (it looks like `1:123…:android:abc…`).
2. **Turn on App Distribution.**
   - Console → **Release & Monitor → App Distribution** → **Get started**.
   - **Testers & Groups** → **Add group** named **friends**, then add your friends' email addresses.
3. **Create a service account so GitHub can upload builds.**
   - Google Cloud console (same project) → **IAM & Admin → Service Accounts** → **Create service account** named `github-releases`.
   - Give it the role **Firebase App Distribution Admin**.
   - Open it → **Keys** → **Add key → JSON**. A file downloads.
4. **Make the signing key.** See "Signing key" below.
5. **Add GitHub secrets.** In the repo: **Settings → Secrets and variables → Actions → New repository secret**:
   - `FIREBASE_ANDROID_APP_ID`: the App ID from step 1.
   - `FIREBASE_SERVICE_ACCOUNT`: the whole contents of the JSON file from step 3. Then delete the file.
   - `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`: from step 4.
6. **Register with Google** (needed in Brazil, Indonesia, Singapore and Thailand now, and everywhere from 2027). Sign up for the free **limited distribution** account in the Android Developer Console, then register `com.wordsmithforge.game` and the signing key's certificate.

### Signing key

One release key signs every build forever. If it's lost, friends reinstall
once; their progress is safe on the server. Two ways to make it:

- **On your computer** (needs Java or Android Studio):
  `keytool -genkeypair -v -keystore wordsmith-upload.jks -alias upload -keyalg RSA -keysize 4096 -validity 10000`
  Then run `base64 -w0 wordsmith-upload.jks` (macOS: `base64 -i wordsmith-upload.jks`) for `ANDROID_KEYSTORE_BASE64`. The alias is `upload`, and the passwords are the ones you chose.
- **Or ask Claude to make one** in its private build machine. It hands you the four secret values in a scratch file to paste into GitHub, and the copy on that machine disappears when the session ends. This is simpler, but the key briefly exists outside your control.

Back up the `.jks` file and its password somewhere safe, such as a password manager.

### Later (M2: accounts and online play)

| Where | What |
|---|---|
| **Firebase console** | **Authentication → Sign-in method**: enable **Google** and **Email/Password**. Add the signing key's **SHA-1 and SHA-256** to the Android app (Project settings), which Google sign-in needs. |
| **Cloudflare dashboard** (free plan) | Create an account. Make an **API token** with Workers Scripts + D1 edit permissions. Note your **account ID**. Add them as the GitHub secrets `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. |

## 6. iPhone (not in v1)

Android only for now. Flutter can build iOS or browser versions later without
a rewrite. iPhone sideloading isn't practical for free, so a **browser version**
would be the cheapest way to add iPhone friends later.
