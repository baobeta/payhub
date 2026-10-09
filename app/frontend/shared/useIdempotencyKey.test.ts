import { describe, expect, it } from "vitest";
import { useIdempotencyKey } from "./useIdempotencyKey";

describe("useIdempotencyKey", () => {
  it("keeps one key across retries and makes a new one when the modal reopens", () => {
    const { key, renew } = useIdempotencyKey();
    const first = key.value;
    expect(key.value).toBe(first); // a retry reads the same key
    renew(); // modal opened again: a new intent
    expect(key.value).not.toBe(first);
  });
});
