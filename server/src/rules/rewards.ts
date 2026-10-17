/**
 * Rewards from the Forge Board and Masterworks (shared/forge-board.md
 * "Rewards"): some XP and some hints, granted by the server.
 *
 * Granting one adds the XP like any other XP (level-ups and their rewards
 * apply) and adds the hints, except that a type the player hasn't unlocked
 * yet becomes the same number of Hammer Strikes. The level that decides is
 * the one before the reward's XP is added.
 */

import { applyXp, HINT_KINDS, isHintUnlocked, levelFromTotalXp, noHints, type HintCounts, type XpAward } from "./progression";

/** `{xp, hints: {hammer, chisel, sparks}}`, every field present. */
export interface Reward {
  readonly xp: number;
  readonly hints: Readonly<HintCounts>;
}

/** A reward of `xp` XP and the given hints (the rest 0). */
export function reward(xp: number, hints: Partial<HintCounts> = {}): Reward {
  return { xp, hints: { ...noHints(), ...hints } };
}

export const NO_REWARD: Reward = reward(0);

/** The reward as a player at `level` gets it: locked hint types become Hammer Strikes. */
export function asGranted(r: Reward, level: number): Reward {
  const hints = noHints();
  for (const kind of HINT_KINDS) {
    if (isHintUnlocked(kind, level)) hints[kind] += r.hints[kind];
    else hints.hammer += r.hints[kind];
  }
  return { xp: r.xp, hints };
}

/** The sum of some rewards. */
export function addRewards(...rs: readonly Reward[]): Reward {
  const hints = noHints();
  let xp = 0;
  for (const r of rs) {
    xp += r.xp;
    for (const kind of HINT_KINDS) hints[kind] += r.hints[kind];
  }
  return { xp, hints };
}

export function isEmptyReward(r: Reward): boolean {
  return r.xp === 0 && HINT_KINDS.every((kind) => r.hints[kind] === 0);
}

export interface RewardGrant {
  /** The reward as granted (after any swap to Hammer Strikes). */
  readonly granted: Reward;
  /** Its XP added to the lifetime total, with any level-ups. */
  readonly award: XpAward;
  /** Every hint to add to the stock: the reward's and the level-up rewards. */
  readonly gained: HintCounts;
}

/** Grants `r` to a player with `totalXp` lifetime XP. */
export function grantReward(totalXp: number, r: Reward): RewardGrant {
  const granted = asGranted(r, levelFromTotalXp(totalXp));
  const award = applyXp(totalXp, granted.xp);
  const gained = noHints();
  for (const kind of HINT_KINDS) gained[kind] = granted.hints[kind] + award.rewards[kind];
  return { granted, award, gained };
}
