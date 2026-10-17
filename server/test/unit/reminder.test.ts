import { describe, expect, it } from "vitest";
import { isReminderHour, MAX_REMINDERS_PER_RUN, reminderBody, reminderMessage } from "../../src/push/reminder";

describe("daily reminders (shared/push.md)", () => {
  it("take a UTC hour 0–23, or null for none", () => {
    for (const ok of [0, 7, 23, null]) expect(isReminderHour(ok)).toBe(true);
    for (const bad of [24, -1, 7.5, "7", undefined, true, [7]]) expect(isReminderHour(bad)).toBe(false);
  });

  it("mention the streak when there is one", () => {
    expect(reminderBody(0)).toBe("A new puzzle is on the anvil.");
    expect(reminderBody(1)).toBe("Keep your 1-day streak going!");
    expect(reminderBody(5)).toBe("Keep your 5-day streak going!");
  });

  it("are an FCM HTTP v1 message as in the contract", () => {
    expect(reminderMessage("tok-1", 5)).toEqual({
      token: "tok-1",
      notification: { title: "Today's Daily Commission is waiting", body: "Keep your 5-day streak going!" },
      data: { type: "daily" },
      android: { priority: "normal", ttl: "3600s", collapse_key: "daily" },
    });
    expect(MAX_REMINDERS_PER_RUN).toBe(500);
  });
});
