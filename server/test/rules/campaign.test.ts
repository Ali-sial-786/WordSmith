import { describe, expect, it } from "vitest";
import { loadCampaignRows, loadEarlierCampaignRows } from "../../scripts/build-campaign-sql.mjs";
import { campaignPuzzle, campaignPuzzleId, editionFor, MASTER_FORGE_LAPS, puzzleStageFor } from "../../src/rules/campaign";

describe("campaignPuzzleId", () => {
  it("pads the stage to 4 digits", () => {
    expect(campaignPuzzleId(1)).toBe("c-0001");
    expect(campaignPuzzleId(600)).toBe("c-0600");
  });
});

describe("campaignPuzzle", () => {
  // shared/puzzle-format.md's example: TEAR across the top, EAT and RATE down from it.
  const example = {
    id: "c-0001",
    letters: "RTAE",
    words: [
      { w: "TEAR", x: 0, y: 0, d: "a" },
      { w: "EAT", x: 1, y: 0, d: "d" },
      { w: "RATE", x: 3, y: 0, d: "d" },
    ],
    bonus: ["ARE", "ART"],
  };

  it("counts letter cells once at crossings and indexes them by row, then column", () => {
    const p = campaignPuzzle(1, example);
    // Row 0: T E A R (4); rows 1-2: E's column and R's column (2 each); row 3: R's column (1).
    expect(p.cellCount).toBe(4 + 2 + 2 + 1);
    expect(p.wordCells.get("TEAR")).toEqual([0, 1, 2, 3]);
    expect(p.wordCells.get("EAT")).toEqual([1, 4, 6]);
    expect(p.wordCells.get("RATE")).toEqual([3, 5, 7, 8]);
    expect([...p.gridWords]).toEqual(["TEAR", "EAT", "RATE"]);
    expect(p.bonus.has("ART")).toBe(true);
  });

  it("refuses data that isn't a puzzle", () => {
    expect(() => campaignPuzzle(1, null)).toThrow();
    expect(() => campaignPuzzle(1, { ...example, words: [] })).toThrow(/words/);
    expect(() => campaignPuzzle(1, { ...example, words: [{ w: "ab", x: 0, y: 0, d: "a" }] })).toThrow(/words/);
    expect(() => campaignPuzzle(1, { ...example, bonus: "ARE" })).toThrow(/bonus/);
  });

  it("parses every puzzle in the real campaign, which matches the format's rules", () => {
    const rows = loadCampaignRows();
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) {
      const p = campaignPuzzle(row.stage, JSON.parse(row.data));
      expect(p.id).toBe(campaignPuzzleId(row.stage));
      expect(p.cellCount).toBeGreaterThanOrEqual(3);
      for (const word of p.bonus) expect(p.gridWords.has(word)).toBe(false);
    }
  });
});

describe("editionFor: results played on an earlier campaign", () => {
  const current = {
    id: "c-0001",
    letters: "RTAE",
    words: [
      { w: "TEAR", x: 0, y: 0, d: "a" },
      { w: "EAT", x: 1, y: 0, d: "d" },
    ],
    bonus: ["ARE", "ART"],
  };
  // Two earlier editions of the stage, newest first: the last one (0.9.0) and the one before (0.8.0).
  const last = { id: "c-0001", letters: "NOTE", words: [{ w: "NOTE", x: 0, y: 0, d: "a" }, { w: "TON", x: 2, y: 0, d: "d" }], bonus: ["ONE"] };
  const older = { id: "c-0001", letters: "NOTE", words: [{ w: "TONE", x: 0, y: 0, d: "a" }, { w: "ONE", x: 1, y: 0, d: "d" }], bonus: ["NOTE", "TON"] };

  it("keeps an earlier puzzle only when it differs from the current one and the newer ones, and has the same id", () => {
    expect(campaignPuzzle(1, current).earlier).toBeUndefined();
    expect(campaignPuzzle(1, current, [current]).earlier).toBeUndefined();
    expect(campaignPuzzle(1, current, [{ ...last, id: "c-0002" }]).earlier).toBeUndefined();
    expect(campaignPuzzle(1, current, [last]).earlier?.map((p) => p.gridWords)).toEqual([new Set(["NOTE", "TON"])]);
    expect(campaignPuzzle(1, current, [last, current, last, older]).earlier?.map((p) => p.gridWords)).toEqual([new Set(["NOTE", "TON"]), new Set(["TONE", "ONE"])]);
  });

  it("picks the current grid if the result fits it, else the newest earlier one it fits, else the current one", () => {
    const p = campaignPuzzle(1, current, [last, older]);
    const [lastP, olderP] = p.earlier!;
    expect(editionFor(p, ["TEAR", "EAT"], ["ART"])).toBe(p);
    expect(editionFor(p, ["NOTE", "TON"], ["ONE"])).toBe(lastP);
    expect(editionFor(p, ["TONE", "ONE"], ["NOTE"])).toBe(olderP);
    // ONE is a grid word of the older edition and a bonus word of the last one: the last one wins when both fit.
    expect(editionFor(p, ["NOTE"], ["ONE"])).toBe(lastP);
    expect(editionFor(p, ["ONE"], [])).toBe(olderP);
    expect(editionFor(p, ["NOTE"], ["ART"])).toBe(p); // a mix: none fits, so the current one rejects it
    expect(editionFor(p, ["ZZZ"])).toBe(p);
    expect(editionFor(p, [])).toBe(p);
    expect(editionFor(campaignPuzzle(1, current), ["NOTE"])).toEqual(campaignPuzzle(1, current));
  });

  it("parses the real earlier campaigns (0.8.0 and 0.9.0), stage for stage with the same ids", () => {
    const rows = loadEarlierCampaignRows();
    const n = loadCampaignRows().length;
    expect(rows).toHaveLength(2 * n);
    for (const row of rows) expect(campaignPuzzle(row.stage, JSON.parse(row.data)).id).toBe(campaignPuzzleId(row.stage));
  });
});

describe("the Master Forge (shared/master-forge.md)", () => {
  it("plays the campaign's puzzles again after its last stage, up to 10 times its length", () => {
    const n = 600;
    expect(MASTER_FORGE_LAPS).toBe(10);
    expect([1, 2, 599, 600].map((s) => puzzleStageFor(s, n))).toEqual([1, 2, 599, 600]);
    // Stage s > N plays b = ((s − N − 1) mod N) + 1.
    expect([601, 602, 1200, 1201, 1450, 6000].map((s) => puzzleStageFor(s, n))).toEqual([1, 2, 600, 1, 250, 600]);
    expect([6001, 0, -1, 1.5].map((s) => puzzleStageFor(s, n))).toEqual([null, null, null, null]);
    // An empty campaign has nothing to play.
    expect(puzzleStageFor(1, 0)).toBeNull();
    expect([1, 2, 3, 4, 7, 30, 31].map((s) => puzzleStageFor(s, 3))).toEqual([1, 2, 3, 1, 1, 3, null]);
  });
});
