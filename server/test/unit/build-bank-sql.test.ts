import { describe, expect, it } from "vitest";
import { bankRows, bankSql, loadBankRows } from "../../scripts/build-bank-sql.mjs";

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
    const sql = bankSql(bankRows({ puzzles: [puzzle(1, { bonus: ["IT'S"] }), puzzle(7)] }));
    expect(sql).toContain("DELETE FROM puzzles WHERE pool = 'mp' AND id NOT IN ('m-00001', 'm-00007');");
    expect(sql).toContain("INSERT OR REPLACE INTO puzzles (id, pool, heat, size, letters, data) VALUES ('m-00001', 'mp', 1, 2, 'RTAE', '");
    expect(sql).toContain(`"IT''S"`);
    expect(sql.endsWith("\n")).toBe(true);
    expect(bankSql([])).toContain("DELETE FROM puzzles WHERE pool = 'mp';");
    expect(bankSql(bankRows({ puzzles: [puzzle(1)] }))).toBe(bankSql(bankRows({ puzzles: [puzzle(1)] })));
  });

  it("reads the real bank: 40 puzzles for every heat and size", () => {
    const rows = loadBankRows();
    expect(rows).toHaveLength(960);
    for (let heat = 1; heat <= 6; heat++) {
      for (let size = 1; size <= 4; size++) expect(rows.filter((r) => r.heat === heat && r.size === size)).toHaveLength(40);
    }
  });
});
