import { describe, expect, it } from "vitest";
import { finishStepUp, requestStepUp, stepUpState } from "./stepUp";

describe("stepUp", () => {
  it("answers every request that asked while the dialog was open", async () => {
    const first = requestStepUp();
    const second = requestStepUp();
    expect(stepUpState.open).toBe(true);
    finishStepUp(true);
    await expect(Promise.all([first, second])).resolves.toEqual([true, true]);
    expect(stepUpState.open).toBe(false);
  });
});
