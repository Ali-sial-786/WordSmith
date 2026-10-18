import { describe, expect, it } from "vitest";
import { bankRows, bankSql, loadBankRows } from "../../scripts/build-bank-sql.mjs";
import { loadCampaignRows } from "../../scripts/build-campaign-sql.mjs";

const puzzle = (n: number, extra: Record<string, unknown> = {}) => ({
  id: `m-${String(n).padStart(5, "0")}`,
  letters: "RTAE",
  heat: 1,
  size: 2,
  cols: 4,
  rows: 1,
  words: [{ w: "TEAR", x: 0, y: 0, d: "a" }],
  bonus: ["ART"],
  ...extra,
});

describe("build-bank-sql", () => {
  it("makes one row per puzzle with its heat, size, letters and JSON", () => {
    const rows = bankRows({ version: 1, puzzles: [puzzle(1), puzzle(2, { heat: 6, size: 4 })] });
    expect(rows.map(({ id, heat, size, letters }) => [id, heat, size, letters])).toEqual([
      ["m-00001", 1, 2, "RTAE"],
      ["m-00002", 6, 4, "RTAE"],
    ]);
    expect(JSON.parse(rows[0]!.data)).toEqual(puzzle(1));
  });

  it("refuses a bank that breaks the format", () => {
    expect(() => bankRows({})).toThrow(/puzzles/);
    expect(() => bankRows({ puzzles: [puzzle(1, { id: "c-0001" })] })).toThrow(/m-NNNNN/);
    expect(() => bankRows({ puzzles: [puzzle(1), puzzle(1)] })).toThrow(/duplicate/);
    expect(() => bankRows({ puzzles: [puzzle(1, { size: 5 })] })).toThrow(/size/);
    expect(() => bankRows({ puzzles: [puzzle(1, { size: undefined })] })).toThrow(/size/);
    expect(() => bankRows({ puzzles: [puzzle(1, { heat: 0 })] })).toThrow(/heat/);
    expect(() => bankRows({ puzzles: [puzzle(1, { letters: "ab" })] })).toThrow(/letters/);
    expect(() => bankRows({ puzzles: [puzzle(1, { words: [{ w: "to", x: 0, y: 0, d: "a" }] })] })).toThrow(/bad word/);
    expect(() => bankRows({ puzzles: [puzzle(1, { words: [{ w: "TEAR", x: 0, y: 0, d: "x" }] })] })).toThrow(/bad slot/);
  });

  it("writes SQL that replaces each puzzle and drops ones no longer in the bank", () => {
    const sql = bankSql(bankRows({ puzzles: [puzzle(1, { bonus: ["IT'S"] }), puzzle(7), puzzle(3), puzzle(2)] }));
    expect(sql).toContain("DELETE FROM puzzles WHERE pool = 'mp' AND NOT (id BETWEEN 'm-00001' AND 'm-00003' OR id = 'm-00007');");
    expect(sql).toContain("INSERT OR REPLACE INTO puzzles (id, pool, heat, size, letters, data) VALUES ('m-00001', 'mp', 1, 2, 'RTAE', '");
    expect(sql).toContain(`"IT''S"`);
    expect(sql.endsWith("\n")).toBe(true);
    expect(bankSql([])).toContain("DELETE FROM puzzles WHERE pool = 'mp';");
    expect(bankSql(bankRows({ puzzles: [puzzle(1)] }))).toBe(bankSql(bankRows({ puzzles: [puzzle(1)] })));
  });

  it("reads the real bank: the first 960 are 40 for every heat and size, then more for Versus and co-op", () => {
    const rows = loadBankRows();
    expect(rows).toHaveLength(3184);
    const count = (list: typeof rows, heat: number, size: number) => list.filter((r) => r.heat === heat && r.size === size).length;
    const first = rows.slice(0, 960);
    for (let heat = 1; heat <= 6; heat++) {
      for (let size = 1; size <= 4; size++) expect(count(first, heat, size)).toBe(40);
      expect(count(rows, heat, 1)).toBe(250);
      for (let size = 2; size <= 4; size++) expect(count(rows, heat, size)).toBeGreaterThanOrEqual(heat === 1 ? 52 : 100);
    }
    expect(rows.map((r) => r.id)).toEqual(rows.map((_, i) => `m-${String(i + 1).padStart(5, "0")}`));
  });

  it("has no names among the words of the real bank and campaign, so rooms and syncs refuse them", () => {
    // Some of tools/puzzlegen/data/names_exclude.txt that anvils often spell.
    const names = new Set(["TED", "DEE", "SAL", "LAS", "MAE", "EROS", "BEN", "ALAN", "LEAR", "TESLA", "BOSTON", "ABIGAIL"]);
    let words = 0;
    for (const row of [...loadBankRows(), ...loadCampaignRows()]) {
      const p = JSON.parse(row.data) as { id: string; words: { w: string }[]; bonus: string[] };
      const all = [...p.words.map((w) => w.w), ...p.bonus];
      words += all.length;
      expect(all.filter((w) => names.has(w)), p.id).toEqual([]);
    }
    expect(words).toBeGreaterThan(100_000);
  });

  it("keeps every statement for the real bank one line, well under D1's 100 KB limit", () => {
    const statements = bankSql(loadBankRows()).trimEnd().split("\n").filter((line) => !line.startsWith("--"));
    expect(statements).toHaveLength(3185);
    for (const s of statements) {
      expect(s.endsWith(";")).toBe(true);
      expect(new TextEncoder().encode(s).length).toBeLessThan(10_000);
    }
  });
});
