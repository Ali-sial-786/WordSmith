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
git tag v0.3.0 && git push --tags
   └─► CI: tests → build signed release APK
          ├─► upload to Firebase App Distribution → "friends" group notified
          ├─► attach APK to a GitHub Release (backup download)
          └─► deploy Worker + run D1 migrations; bump /v1/version
```

## 5. One-time setup (things only you can do)

I'll walk you through each of these when we reach them. Secrets go into GitHub
repository settings, **never into chat**.

| # | Where | What | When |
|---|---|---|---|
| 1 | **Firebase console** (free Spark plan) | Create the project. Turn on **Authentication → Google** and **Email/Password**. Add the Android app with the package name and the key's SHA fingerprints. Turn on **App Distribution** and create a **"friends"** tester group. | Before M2 (App Distribution before the first friend build, end of M1) |
| 2 | **Cloudflare dashboard** (free plan) | Create an account. Make an **API token** with Workers + D1 edit permissions. Note your **account ID**. | Before M2 |
| 3 | **GitHub → Settings → Secrets** | `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `FIREBASE_SERVICE_ACCOUNT` (to upload to App Distribution), `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | End of M1 |
| 4 | **Android Developer Console** | Sign up for the free **limited distribution** account, then register the package name and signing key. | Before the first friend build |
| 5 | **Firebase App Distribution** | Add your friends' emails to the "friends" group. | First friend build |

## 6. iPhone (not in v1)

Android only for now. Flutter can build iOS or browser versions later without
a rewrite. iPhone sideloading isn't practical for free, so a **browser version**
would be the cheapest way to add iPhone friends later.
