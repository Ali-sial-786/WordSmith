import { DatabaseSync } from "node:sqlite";
import { describe, expect, it } from "vitest";
import { campaignRows, campaignSql, EARLIER_EDITIONS, loadCampaignRows, loadEarlierCampaignRows } from "../../scripts/build-campaign-sql.mjs";

const puzzle = (stage: number, extra: Record<string, unknown> = {}) => ({
  id: `c-${String(stage).padStart(4, "0")}`,
  letters: "RTAE",
  heat: 1,
  cols: 4,
  rows: 1,
  words: [{ w: "TEAR", x: 0, y: 0, d: "a" }],
  bonus: ["ART"],
  ...extra,
});

// migrations/0012_campaign_editions.sql
const EDITIONS_TABLE =
  "CREATE TABLE campaign_previous (edition INTEGER NOT NULL, stage INTEGER NOT NULL, puzzle_id TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY (edition, stage));";

describe("build-campaign-sql", () => {
  it("makes one row per stage with the puzzle JSON", () => {
    const rows = campaignRows({ version: 1, puzzles: [puzzle(1), puzzle(2)] });
    expect(rows.map((r) => [r.stage, r.puzzleId])).toEqual([
      [1, "c-0001"],
      [2, "c-0002"],
    ]);
    expect(JSON.parse(rows[0]!.data)).toEqual(puzzle(1));
  });

  it("refuses a campaign that breaks the format", () => {
    expect(() => campaignRows({})).toThrow(/puzzles/);
    expect(() => campaignRows({ puzzles: [puzzle(2)] })).toThrow(/stage 1: id/);
    expect(() => campaignRows({ puzzles: [puzzle(1, { words: [{ w: "to", x: 0, y: 0, d: "a" }] })] })).toThrow(/bad word/);
  });

  it("writes SQL that upserts each stage and drops ones that no longer exist", () => {
    const sql = campaignSql(campaignRows({ puzzles: [puzzle(1, { bonus: ["IT'S"] })] }));
    expect(sql).toContain("DELETE FROM campaign WHERE stage > 1;");
    expect(sql).toContain(`INSERT INTO campaign (stage, puzzle_id, data) VALUES (1, 'c-0001', '`);
    expect(sql).toContain("ON CONFLICT (stage) DO UPDATE SET");
    expect(sql).toContain(`"IT''S"`);
    expect(sql.endsWith("\n")).toBe(true);
    // Same input, same output.
    expect(campaignSql(campaignRows({ puzzles: [puzzle(1)] }))).toBe(campaignSql(campaignRows({ puzzles: [puzzle(1)] })));
  });

  it("loading it again writes nothing unless a stage changed (deploys run it every time)", () => {
    const db = new DatabaseSync(":memory:");
    db.exec("CREATE TABLE campaign (stage INTEGER PRIMARY KEY, puzzle_id TEXT NOT NULL, data TEXT NOT NULL);");
    db.exec(EDITIONS_TABLE);
    const load = (sql: string) =>
      sql
        .split("\n")
        .filter((line) => line !== "" && !line.startsWith("--"))
        .reduce((n, line) => n + Number(db.prepare(line).run().changes), 0);
    expect(load(campaignSql(campaignRows({ puzzles: [puzzle(1), puzzle(2)] })))).toBe(2);
    expect(load(campaignSql(campaignRows({ puzzles: [puzzle(1), puzzle(2)] })))).toBe(0);
    expect(load(campaignSql(campaignRows({ puzzles: [puzzle(1), puzzle(2, { bonus: ["TAR"] })] })))).toBe(1);
  });

  it("loads each earlier edition into campaign_previous, and drops editions no longer listed", () => {
    const db = new DatabaseSync(":memory:");
    db.exec("CREATE TABLE campaign (stage INTEGER PRIMARY KEY, puzzle_id TEXT NOT NULL, data TEXT NOT NULL);");
    db.exec(EDITIONS_TABLE);
    const load = (sql: string) =>
      sql
        .split("\n")
        .filter((l) => l !== "" && !l.startsWith("--"))
        .reduce((n, l) => n + Number(db.prepare(l).run().changes), 0);
    const rows = campaignRows({ puzzles: [puzzle(1), puzzle(2)] });
    const edition = (n: number, puzzles: unknown[]) => campaignRows({ puzzles }).map((r) => ({ edition: n, ...r }));
    const first = edition(1, [puzzle(1, { bonus: ["RAT"] }), puzzle(2, { bonus: ["TAR"] })]);
    const second = edition(2, [puzzle(1, { bonus: ["EAT"] })]);
    expect(load(campaignSql(rows, [...first, ...second]))).toBe(5);
    const count = (t: string) => Number((db.prepare(`SELECT COUNT(*) AS n FROM ${t}`).all()[0] as { n: number }).n);
    expect([count("campaign"), count("campaign_previous")]).toEqual([2, 3]);
    const bonus = (e: number, stage: number) =>
      JSON.parse((db.prepare(`SELECT data FROM campaign_previous WHERE edition = ${e} AND stage = ${stage}`).all()[0] as { data: string }).data).bonus;
    expect([bonus(1, 2), bonus(2, 1)]).toEqual([["TAR"], ["EAT"]]);
    // Again: nothing written.
    expect(load(campaignSql(rows, [...first, ...second]))).toBe(0);
    // An edition dropped from the list, and one that lost a stage.
    load(campaignSql(rows, edition(1, [puzzle(1, { bonus: ["RAT"] })])));
    expect((db.prepare("SELECT edition, stage FROM campaign_previous").all() as { edition: number; stage: number }[]).map((r) => [r.edition, r.stage])).toEqual([[1, 1]]);
    load(campaignSql(rows));
    expect([count("campaign"), count("campaign_previous")]).toEqual([2, 0]);
  });

  it("reads the committed earlier editions: the campaigns of app 0.8.0 and 0.9.0", () => {
    expect(EARLIER_EDITIONS.map((e) => [e.edition, e.app])).toEqual([
      [1, "0.8.0"],
      [2, "0.9.0"],
    ]);
    const earlier = loadEarlierCampaignRows();
    expect(earlier).toHaveLength(1200);
    expect(earlier.filter((r) => r.edition === 2).map((r) => r.stage)).toEqual([...Array(600).keys()].map((i) => i + 1));
    // Each differs from the current campaign, and from the other.
    const current = loadCampaignRows();
    for (const e of [1, 2]) expect(earlier.find((r) => r.edition === e && r.stage === 100)!.data).not.toBe(current[99]!.data);
    expect(earlier[99]!.data).not.toBe(earlier[699]!.data);
    expect(loadEarlierCampaignRows([{ edition: 1, app: "0.0.1", path: "/no/such/file.json" }])).toEqual([]);
  });
});
