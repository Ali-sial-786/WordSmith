import { DatabaseSync } from "node:sqlite";
import { describe, expect, it } from "vitest";
import { campaignRows, campaignSql, loadPreviousCampaignRows } from "../../scripts/build-campaign-sql.mjs";

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
    db.exec("CREATE TABLE campaign_previous (stage INTEGER PRIMARY KEY, puzzle_id TEXT NOT NULL, data TEXT NOT NULL);");
    const load = (sql: string) =>
      sql
        .split("\n")
        .filter((line) => line !== "" && !line.startsWith("--"))
        .reduce((n, line) => n + Number(db.prepare(line).run().changes), 0);
    expect(load(campaignSql(campaignRows({ puzzles: [puzzle(1), puzzle(2)] })))).toBe(2);
    expect(load(campaignSql(campaignRows({ puzzles: [puzzle(1), puzzle(2)] })))).toBe(0);
    expect(load(campaignSql(campaignRows({ puzzles: [puzzle(1), puzzle(2, { bonus: ["TAR"] })] })))).toBe(1);
  });

  it("loads the previous campaign into its own table, and empties it when there is none", () => {
    const db = new DatabaseSync(":memory:");
    for (const t of ["campaign", "campaign_previous"]) db.exec(`CREATE TABLE ${t} (stage INTEGER PRIMARY KEY, puzzle_id TEXT NOT NULL, data TEXT NOT NULL);`);
    const load = (sql: string) => sql.split("\n").filter((l) => l !== "" && !l.startsWith("--")).forEach((l) => db.prepare(l).run());
    const rows = campaignRows({ puzzles: [puzzle(1), puzzle(2)] });
    const old = campaignRows({ puzzles: [puzzle(1, { bonus: ["RAT"] }), puzzle(2, { bonus: ["TAR"] })] });
    load(campaignSql(rows, old));
    const count = (t: string) => Number((db.prepare(`SELECT COUNT(*) AS n FROM ${t}`).all()[0] as { n: number }).n);
    expect([count("campaign"), count("campaign_previous")]).toEqual([2, 2]);
    expect(JSON.parse((db.prepare("SELECT data FROM campaign_previous WHERE stage = 2").all()[0] as { data: string }).data).bonus).toEqual(["TAR"]);
    load(campaignSql(rows));
    expect([count("campaign"), count("campaign_previous")]).toEqual([2, 0]);
  });

  it("reads the committed previous campaign (the one before the quality-scored words)", () => {
    const previous = loadPreviousCampaignRows();
    expect(previous).toHaveLength(600);
    expect(loadPreviousCampaignRows("/no/such/file.json")).toEqual([]);
  });
});
