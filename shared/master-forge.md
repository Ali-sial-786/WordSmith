# Master Forge (shared contract)

After the last campaign stage, the campaign keeps going, like the genre's
"master levels": every puzzle comes round again, at full XP.

- Let `N` be the number of campaign stages. Stage `s > N` is a **Master
  Forge** stage. It plays the campaign puzzle of stage
  `b = ((s − N − 1) mod N) + 1`, with that puzzle's `puzzleId`.
- The app shows it as "Master Forge · Puzzle `s − N`", in a tenth chapter
  after Starmetal that opens once the campaign is complete.
- Solo sync accepts stages up to `10 × N` (a stage beyond is
  `unknown_stage`). `N` is the server's campaign as loaded (its last stage).
  For `s > N` the server checks the
  entry against puzzle `b` (`puzzle_mismatch` if `puzzleId` isn't `b`'s id)
  and otherwise treats it exactly like a campaign stage: XP, Scrap Bin,
  pickups and gilded cells (seeded from `puzzleId` as usual), each stage
  counted once, and `campaignCompleted` / `nextStage` keep counting up past
  `N`.
- Work Orders count Master Forge stages as campaign puzzles.
