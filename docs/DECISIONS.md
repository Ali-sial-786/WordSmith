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
| 2026-10-17 | **English only. No free-text chat** (preset emotes instead). | — |
