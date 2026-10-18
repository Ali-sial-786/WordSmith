# Wordsmith — Sharing It With Friends

> Status: **in use.** Builds are signed with the permanent release key.
>
> **Approach:** no Play Store. Each release is a signed **APK** on the repo's
> **GitHub Releases** page, and the owner sends it to friends directly (chat,
> email, Drive). That means no $25 fee and none of the Play rules (closed
> testing, data safety form, store listing). Firebase App Distribution was
> dropped on 2026-10-17 (DECISIONS.md). iPhone friends play the browser
> version at https://play.wordsmith-forge.workers.dev (§6).

---

## 1. How friends install and update

1. You download the APK from the repo's **Releases** page (or Claude sends it) and send the file to friends.
2. They open it on their phone. The first time, Android asks them to **allow installs from this source** (the chat or file app they opened it from). Google Play Protect may warn that the app is from an unknown developer, and they tap **Install anyway**.
3. **Updates:** from 0.4.2 on, the game updates itself. Every build is signed with the same key, so it installs over the old one.
   - When `/v1/version` says a newer version is out, the Forge Hall shows a banner with **Update now**. Settings → **Version** checks again on a tap.
   - **Update now** downloads the new APK from its GitHub Release (`apk` in `/v1/version`, from `APK_URL` in `server/wrangler.jsonc`) with a progress bar, checks it's Wordsmith at that version, and opens Android's installer. The player taps **Update** there; progress stays.
   - The first time, Android asks them to let Wordsmith **install unknown apps**; the game opens that switch and carries on when they come back.
   - Sending the APK by hand still works, and is the only way onto 0.4.1 or older.
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
   (the server deploys separately: .github/workflows/deploy-server.yml,
    and the browser version on every app change: deploy-web.yml, §6)
```

**Publish the release before the server announces it.** The app downloads
updates from the release (`APK_URL`), so bump `LATEST_VERSION` in
`server/wrangler.jsonc` in a commit marked `[skip ci]`, publish the release,
then run **Deploy server**. Otherwise players who tap **Update now** in
between hear that the update is still on its way, and to try again shortly.

Where tags can't be pushed (Claude's cloud sessions can only push their
branch), run **Actions → Release (friends build) → Run workflow** with
**publish** ticked instead: it builds the same APK and publishes the release
for pubspec's version, tagging the commit it ran on. The latest APK is always
at `https://github.com/Ali-sial-786/WordSmith/releases/latest`.

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

**Video chat (LiveKit, free):** optional.
1. Sign up at **https://cloud.livekit.io** (Google or GitHub login) on the free **Build** plan and create a project named `wordsmith`.
2. **Settings → API Keys → Create key.** Note the project URL (`wss://….livekit.cloud`), the API key and the API secret (shown once).
3. Add the GitHub **secrets** `LIVEKIT_URL`, `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET`.
4. GitHub → **Actions → Deploy server → Run workflow** (or wait for the next server change). The run copies them to the Worker.

**Invite notifications (Firebase Cloud Messaging, free):** optional.
1. Firebase console → ⚙ **Project settings** → **Cloud Messaging**: check that **Firebase Cloud Messaging API (V1)** says *Enabled*.
2. **Project settings → Service accounts → Generate new private key.** A JSON file downloads.
3. Add a GitHub **secret** named `FCM_SERVICE_ACCOUNT` containing the whole JSON file, then delete the file.
4. GitHub → **Actions → Deploy server → Run workflow**. The run copies it to the Worker. Friends get a notification when invited, and tapping it opens the room.

Developer note: local builds read these settings from `app/dart_defines.json` (git-ignored), with
`flutter build apk --dart-define-from-file=dart_defines.json`.

## 6. Browser and iPhone

iPhone sideloading isn't practical for free, so iPhone friends play the
**browser version**: the same Flutter app built for the web, tuned for iOS
Safari and for installing to the Home Screen.

**URL:** **https://play.wordsmith-forge.workers.dev** (it also works in
Chrome on Android and on a computer).

### How it deploys

```
push to the default branch touching app/ (not app/android/) or webhost/
   └─► .github/workflows/deploy-web.yml: flutter test → flutter build web
          → check Cloudflare's limits → npx wrangler deploy (webhost/)
          → wait until the live version.json shows the new version
```

- **Hosting:** a second Cloudflare Worker, **`play`**, next to the API Worker (`wordsmith-api`). It has no code: `webhost/wrangler.jsonc` serves `app/build/web` with Workers Static Assets (free plan: up to 20,000 files and 25 MiB per file; the build is about 210 files and 42 MiB, the biggest file 7 MiB, and the workflow checks this on every run).
- **Secrets:** nothing new. It uses the same `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` as the server (§5), plus `FIREBASE_ANDROID_API_KEY` for accounts, and the optional `API_BASE_URL` variable. Without the Cloudflare secrets it skips with a notice. The first run creates the `play` Worker.
- **By hand:** **Actions → Deploy web → Run workflow**. The run's summary shows the URL and the version.
- **Updates reach players** on their next start: the page, `flutter_bootstrap.js`, `main.dart.js`, `version.json` and `manifest.json` are served `no-cache`, so the browser checks for a new copy every time. The renderer (`canvaskit/`), images, sounds, fonts and word lists are cached for a day (`app/web/_headers`). There's no service worker, so nothing can keep an old build alive. A Home Screen app that's reopened after 15 minutes or more away reloads itself if a newer build is live.
- **The web shell** is `app/web/`: `index.html` (loading screen, safe areas, Home Screen settings, the install hint), `flutter_bootstrap.js` (starts the game inside the safe area), `manifest.json`, `_headers` and `.assetsignore` (for Cloudflare), and three plain pages for the app and a store listing to link to: `privacy.html`, `terms.html` and `delete-account.html`, served at `/privacy`, `/terms` and `/delete-account` (they share one set of styles, so change all three together; each has its contact details in one `id="contact"` spot). `python3 art/web_icons.py` rebuilds the icons and the iPhone launch images from `art/icon/`.
- **Locally:** `cd app && flutter build web --release --no-web-resources-cdn --dart-define-from-file=dart_defines.json`, then `cd ../webhost && npx wrangler@4.151.1 dev` (the same headers as Cloudflare) or `python3 -m http.server -d ../app/build/web`.

### How friends install it on an iPhone

1. Open **https://play.wordsmith-forge.workers.dev** in **Safari**.
2. Tap **Share** (on iOS 26 and later, tap **⋯** first, then **Share**), then **Add to Home Screen**, then **Add**. On iOS 26, leave **Open as Web App** switched on.
3. Wordsmith now has its own icon. It opens full screen like an app, without Safari's bars.
4. **Sign in** with the same account as on Android: progress lives on the server. The Home Screen app doesn't share Safari's storage, so sign in again there if you first played in Safari.

The game shows a one-time hint with these steps the first time it's opened in
Safari. Updates need nothing: the next start loads the latest version.

### Limits on iPhone

- **Sound needs a first tap**, as on every website. After that it plays even with the ring/silent switch on (iOS 17 and later).
- **No sound in the background.** Voice chat stops when Safari or the Home Screen app is closed or in the background, unlike the Android app. (Music pauses off screen on both.)
- **No push notifications** (invites) in Safari. iOS only allows web notifications for apps added to the Home Screen on **iOS 16.4 or later**, and the browser version doesn't support them yet, so invites only show while the game is open.
- **Storage:** Safari can clear a website's saved data after about 7 days without a visit (not for Home Screen apps). Signed-in progress is safe on the server; settings and a signed-out player's progress may be lost.
- **First start** downloads about 6 MB (the renderer, the game and its pictures) and takes a few seconds; later starts use the cache.
- No vibration, and the screen can rotate if the iPhone's rotation lock is off (iOS ignores the portrait setting for web apps).

## 7. Reports and blocks

Players can block and report each other from room chat, the lobby and the
friends list (shared/safety.md). Blocks are the player's own; reports wait
for you in the database:

1. Cloudflare dashboard › **Storage & databases › D1 › wordsmith › Console**.
2. Open reports, newest first:
   `SELECT id, created_at, reason, reported_username, details, room, lines FROM reports WHERE status = 'open' ORDER BY created_at DESC;`
   (`created_at` is epoch milliseconds; `lines` holds the reported player's
   chat lines as the reporter saw them.)
3. Once handled: `UPDATE reports SET status = 'done' WHERE id = 12;`

Check them every few days once the game reaches people you don't know: app
stores expect reports to be acted on. There's no ban tool yet; ask for one
when it's needed.

## 8. The Google Play version (later, not started)

The owner decided (2026-10-18) to stay on GitHub Releases and the browser for
now. When a Play version is made, it is a **separate build** with only these
two differences from the friends' APK; everything else stays the same:

1. **No background voice.** Voice and video chat stop when the game leaves the
   screen (switching apps or locking the phone) and reconnect when it comes
   back. That drops `GameAudioService`, its microphone and media-playback
   foreground service and their permissions, so the Play Console needs no
   foreground-service declaration or demo video.
2. **No in-app updater.** Play updates the app itself: the update banner, the
   Settings "check for updates" row and the `REQUEST_INSTALL_PACKAGES`
   permission are left out (Play doesn't allow apps to update themselves).

Already done for it (in every version): report and block buttons, a privacy
policy (`/privacy`), terms and chat rules (`/terms`) and an account-deletion
page (`/delete-account`) on the web version, and in-app account deletion.

Still to do on the Play Console when the time comes:
- A Play developer account: $25 once, with ID verification. New personal
  accounts must run a **closed test with at least 12 testers for 14 days in a
  row** before going public (an organisation account is exempt).
- Upload an **Android App Bundle** (`.aab`) signed with the existing key; Play
  App Signing then holds the release key.
- Store listing, content rating questionnaire (13+ is simplest with chat and
  voice), target audience, **Data safety** form (matching `/privacy`), the
  privacy policy URL and the account-deletion URL.
- Target the Android version Play currently requires (Android 16, API 36,
  from August 31, 2026; the app already does).
