import { describe, expect, it } from "vitest";
import { ADULT_AGE, ageAt, MIN_AGE, parseBirth } from "../../src/rules/age";

const at = (iso: string) => Date.parse(iso);

describe("ages (shared/age.md)", () => {
  it("counts a birthday only once its month is over", () => {
    const now = at("2026-10-18T12:00:00Z");
    expect(ageAt({ year: 2013, month: 9 }, now)).toBe(13);
    expect(ageAt({ year: 2013, month: 10 }, now)).toBe(12);
    expect(ageAt({ year: 2013, month: 11 }, now)).toBe(12);
    expect(ageAt({ year: 2008, month: 10 }, now)).toBe(17);
    expect(ageAt({ year: 2008, month: 9 }, now)).toBe(18);
    expect(ageAt({ year: 2013, month: 10 }, at("2026-11-01T00:00:00Z"))).toBe(MIN_AGE);
    expect(ageAt({ year: 2008, month: 10 }, at("2026-11-01T00:00:00Z"))).toBe(ADULT_AGE);
  });

  it("takes a month 1-12 and a year from 120 years ago to now, never in the future", () => {
    const now = at("2026-10-18T12:00:00Z");
    expect(parseBirth(2000, 1, now)).toEqual({ year: 2000, month: 1 });
    expect(parseBirth(2026, 10, now)).toEqual({ year: 2026, month: 10 });
    expect(parseBirth(1906, 12, now)).toEqual({ year: 1906, month: 12 });
    for (const [year, month] of [
      [2026, 11],
      [2027, 1],
      [1905, 6],
      [2000, 0],
      [2000, 13],
      [2000.5, 3],
      ["2000", 3],
      [2000, null],
      [undefined, 3],
    ]) {
      expect(parseBirth(year, month, now), `${year}-${month}`).toBeNull();
    }
  });
});
