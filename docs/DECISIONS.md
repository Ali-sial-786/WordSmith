# Decisions Log

The choices agreed so far, newest at the bottom. If something here changes,
update the relevant plan document too.

| Date | Decision | Notes |
|---|---|---|
| 2026-10-17 | **Game:** Wordscapes / Word Trails–style word puzzle called **Wordsmith**, with a blacksmithing theme. | Mechanics follow the genre closely. Art, sounds and puzzles are our own or properly licensed. |
| 2026-10-17 | **Platform:** Android only for v1, built with **Flutter**. | Flutter keeps iOS and a browser version open for later. |
| 2026-10-17 | **Audience:** just the owner and their friends. **No Play Store.** | The APK is shared through Firebase App Distribution, using Google's free limited distribution account (up to 20 devices) to meet developer verification. |
| 2026-10-17 | **Backend:** Cloudflare Workers + **Durable Objects** (one referee per room) + D1, with **Firebase Authentication**. Target cost **$0/month**. | Chosen over Nakama on a paid server (cost) and Supabase or Firebase-only (no game loop, pauses, connection caps). |
| 2026-10-17 | **Sign-in:** Google and email/password. | Guest accounts dropped, since every player is a friend with an account. Easy to add back. |
| 2026-10-17 | **Levels:** an XP-based **Smith Level** earned in every mode. The host's level sets co-op difficulty. | Separate from the campaign puzzle number. |
| 2026-10-17 | **Co-op:** up to 4 players on one shared, timed puzzle. Whoever enters a word first gets its points. The results show who on the team scored most. | — |
| 2026-10-17 | **Versus:** up to 5 players, same puzzle, **each on their own mold**. **First to finish wins the round**, and if time runs out the round ends. | — |
| 2026-10-17 | **VS timeout:** the most letters filled wins the round; a tie goes to whoever reached that count first. | — |
| 2026-10-17 | **VS series:** best of **3, 5, 7 or 10**, chosen by the host. Round wins add up, and the series ends early once someone can't be caught. A **tie** is settled by a **sudden-death round** between the tied players. | — |
| 2026-10-17 | **No Quick Match.** Rooms are joined by code, invite or the friends' open-rooms list. | It's friends-only. |
| 2026-10-17 | **Hints** are items, not bought with currency. They're **unlocked and granted by levelling up**, found as **random pickups in puzzles**, and earned from the Scrap Bin (bonus words). There's **no cap**, so players can save them up. There's no in-game currency in v1. | In co-op each player spends their own hints, and hinted letters score nothing. In VS, hints can't be used, but pickups found in VS are kept for later. |
| 2026-10-17 | **Assets:** free, properly licensed assets first (CC0 preferred). Our own in Blender, Inkscape or code where those don't fit. | Rules in [ART_AND_AUDIO.md](ART_AND_AUDIO.md). |
| 2026-10-17 | **English only. No free-text chat** (preset emotes instead). | Text chat in rooms replaced the second half on 2026-10-18 (below). |
| 2026-10-17 | **App ID (package name):** `com.wordsmithforge.game`. | No personal username in it. Confirmed when it's registered in the limited distribution account. |
| 2026-10-17 | **Firebase project:** `wordsmith-8f550` (Spark, free plan), owned by the project owner's Google account. | Used for sign-in (M2) and App Distribution. The project ID is not a secret; service-account keys are, and they go only in GitHub secrets. |
| 2026-10-17 | **No Firebase App Distribution.** Releases are GitHub Releases with the signed APK attached; the owner sends the file to friends. | Simpler for the owner (no tester group, service account or App Tester app). Updates install over the old version because every build uses the same signing key. |
| 2026-10-17 | **Optional video chat in rooms through LiveKit Cloud** (free Build plan). Small live bubbles replace avatars; voice included. Off by default. | Smoother than Cloudflare Realtime in Flutter today (mature SDK with adaptive streaming and reconnection); WhatsApp can't be embedded and Zoom's SDK is heavier. Voice and video are between friends in the same room only; there's still no text chat. |
| 2026-10-18 | **Text chat in Co-op and Versus rooms**, replacing "no free-text chat" (the owner asked for it). Emotes stay. | Room-only, no private messages and nothing kept once the room closes. Profanity is starred out on the server, lines are rate-limited, players can mute each other on their own phone, and Settings can turn it off. There's still no moderation team or reporting; worth adding before the game reaches strangers or children. |
