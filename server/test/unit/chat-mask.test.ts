import { describe, expect, it } from "vitest";
import { maskProfanity } from "../../src/account/profanity";

describe("maskProfanity (room chat)", () => {
  it.each([
    ["what the fuck", "what the ****"],
    ["Sh1t, so close", "****, so close"],
    ["you ass", "you ***"],
    ["nice tits", "nice ****"],
    ["f_u_c_k this", "******* this"],
    ["FUCKING hard one", "******* hard one"],
  ])("stars out %j", (text, masked) => {
    expect(maskProfanity(text)).toBe(masked);
  });

  it.each(["Good game!", "a classic class", "this analysis passes", "glasses on, cocktail after", "Sussex dickens 🔥", "gg 2 v 1"])("leaves %j alone", (text) => {
    expect(maskProfanity(text)).toBe(text);
  });
});
