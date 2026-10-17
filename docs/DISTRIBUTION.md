# Wordsmith — Sharing It With Friends

> Status: **in use.** Builds are signed with the permanent release key.
>
> **Approach:** no Play Store. Each release is a signed **APK** on the repo's
> **GitHub Releases** page, and the owner sends it to friends directly (chat,
> email, Drive). That means no $25 fee and none of the Play rules (closed
> testing, data safety form, store listing). Firebase App Distribution was
> dropped on 2026-10-17 (DECISIONS.md).

---

## 1. How friends install and update

1. You download the APK from the repo's **Releases** page (or Claude sends it) and send the file to friends.
2. They open it on their phone. The first time, Android asks them to **allow installs from this source** (the chat or file app they opened it from). Google Play Protect may warn that the app is from an unknown developer, and they tap **Install anyway**.
3. **Updates:** send the new APK the same way. Every build is signed with the same key, so it installs over the old one.
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
          ├─► GitHub Release "Wordsmith 0.3.0" with wordsmith-0.3.0.apk attached
          └─► the same APK as a workflow artifact (30 days)
   (the server deploys separately: .github/workflows/deploy-server.yml)
```

**The GitHub repository is public**, so anyone who finds the Releases page
can download the APK. It holds nothing secret (the Firebase API key and
server URL ship in every APK anyway), but strangers could install it and make
an account. Making the repository private hides it; private repos still get
2,000 free Actions minutes a month.

The signing key and its passwords must only ever live in **GitHub Actions
secrets** (and your own backup), never in a commit or an artifact.
The release workflow writes the key to disk only for the build and deletes it
afterwards.

## 5. One-time setup (things only you can do)

Secrets go into GitHub repository settings, **never into chat or a commit**.
The Firebase project already exists: **`wordsmith-8f550`**.

### For friend builds

1. **Add the Android app to Firebase.** Done: package `com.wordsmithforge.game`, App ID `1:920525083065:android:64d3e8d63203074d96e668`.
2. **Make the signing key.** Done on 2026-10-17 (see "Signing key" below).
3. **Add GitHub secrets.** In the repo: **Settings → Secrets and variables → Actions → New repository secret**:
   - `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`: from step 2.
   - `FIREBASE_ANDROID_API_KEY`: the `current_key` value in `google-services.json` (see M2 below).
4. **Register with Google** (needed in Brazil, Indonesia, Singapore and Thailand now, and everywhere from 2027). Sign up for the free **limited distribution** account in the Android Developer Console, then register `com.wordsmithforge.game` and the signing key's certificate.

### Signing key

One release key signs every build forever. If it's lost, friends reinstall
once; their progress is safe on the server. Two ways to make it:

- **On your computer** (needs Java or Android Studio):
  `keytool -genkeypair -v -keystore wordsmith-upload.jks -alias upload -keyalg RSA -keysize 4096 -validity 10000`
  Then run `base64 -w0 wordsmith-upload.jks` (macOS: `base64 -i wordsmith-upload.jks`) for `ANDROID_KEYSTORE_BASE64`. The alias is `upload`, and the passwords are the ones you chose.
- **Or ask Claude to make one** in its private build machine. It hands you the four secret values in a scratch file to paste into GitHub, and the copy on that machine disappears when the session ends. This is simpler, but the key briefly exists outside your control.

Back up the `.jks` file and its password somewhere safe, such as a password manager.

### For accounts and online play (M2)

**Firebase sign-in** (console → **Build → Authentication**):
1. **Sign-in method** tab → **Email/Password** → switch on → **Save**.
2. Add a GitHub **secret** named `FIREBASE_ANDROID_API_KEY` set to the `current_key` value in `google-services.json`. It isn't truly secret, but it stays out of the public repo so GitHub's secret scanning doesn't raise alarms.
3. **"Continue with Google":** enable the **Google** provider, then add the release signing key's **SHA-1 and SHA-256** under Project settings → Your apps → Wordsmith → **Add fingerprint**. The key made on 2026-10-17 has:
   - SHA-1 `42:82:86:FC:5C:E2:AF:62:DA:29:2F:D8:DB:F6:B8:13:75:0D:28:6A`
   - SHA-256 `D3:A2:A8:BC:A9:59:5F:1F:C4:F9:F2:A5:5D:29:F3:43:F2:87:CB:B9:7C:2F:C8:1E:31:9C:1D:DB:BD:92:34:3E`

   The app also needs the project's **web client ID** (in the new `google-services.json`, the `oauth_client` entry with `"client_type": 3`). It's public and lives in `app/lib/net/config.dart`. Only builds signed with a registered key can use Google sign-in.

**Cloudflare (free plan):** this is where the server runs.
1. Create a free account at **dash.cloudflare.com** (email sign-up).
2. Open **Workers & Pages** once and pick a **workers.dev subdomain** (e.g. `wordsmith-forge`). The server will live at `https://wordsmith-api.<subdomain>.workers.dev`.
3. Note your **Account ID**. It's shown on the Workers & Pages overview page, in the right-hand column.
4. **My Profile → API Tokens → Create Token** → use the template **"Edit Cloudflare Workers"** → under Permissions, **add** "Account · D1 · Edit" → limit it to your account → **Create Token** and copy it (it's shown once).
5. In GitHub, add the repository **secrets** `CLOUDFLARE_API_TOKEN` (the token) and `CLOUDFLARE_ACCOUNT_ID`.
6. GitHub → **Actions → Deploy server → Run workflow**. On its first run it creates the database, loads the campaign and deploys. The run's summary shows the **server URL**.
7. The live URL, `https://wordsmith-api.wordsmith-forge.workers.dev`, is built into the app (`app/lib/net/config.dart`). The optional repository **variable** `API_BASE_URL` overrides it for friend builds.

Developer note: local builds read these settings from `app/dart_defines.json` (git-ignored), with
`flutter build apk --dart-define-from-file=dart_defines.json`.

## 6. iPhone (not in v1)

Android only for now. Flutter can build iOS or browser versions later without
a rewrite. iPhone sideloading isn't practical for free, so a **browser version**
would be the cheapest way to add iPhone friends later.
