import { describe, expect, it } from "vitest";
import { pollIntervalFor } from "./pollInterval";

describe("pollIntervalFor", () => {
  it("stops for terminal states", () => {
    for (const s of ["canceled", "failed", "refunded"] as const) expect(pollIntervalFor(s)).toBe(false);
  });

  it("keeps polling while the outcome is open, at a sane rate", () => {
    for (const s of ["pending", "unknown", "requires_action", "authorized", "captured", "part_refunded"] as const) {
      const ms = pollIntervalFor(s);
      expect(ms).not.toBe(false);
      expect(ms).toBeGreaterThanOrEqual(1000);
      expect(ms).toBeLessThanOrEqual(30000);
    }
  });

  it("polls unknown slower than pending: the sweeper, not the page, resolves it", () => {
    expect(pollIntervalFor("unknown")).toBeGreaterThan(pollIntervalFor("pending") as number);
  });
});
