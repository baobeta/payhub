import { describe, expect, it } from "vitest";
import { can } from "./can";

describe("can", () => {
  it("is true only for granted permissions", () => {
    expect(can(["payments.read"], "payments.read")).toBe(true);
    expect(can(["payments.read"], "payments.refund")).toBe(false);
  });
});
