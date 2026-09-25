import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiFailure, createClient } from "./http";

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), { status });
}

describe("createClient", () => {
  beforeEach(() => {
    document.head.innerHTML = '<meta name="csrf-token" content="tok123">';
  });
  afterEach(() => vi.restoreAllMocks());

  it("sends the CSRF token and the idempotency key on writes", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(json({}, 200));
    const api = createClient("/dashboard/api");
    await api.post("/payments/p1/refunds", { amount_minor: 1 }, { idempotencyKey: "k1" });
    const [url, init] = fetchMock.mock.calls[0];
    const headers = init!.headers as Record<string, string>;
    expect(url).toBe("/dashboard/api/payments/p1/refunds");
    expect(headers["X-CSRF-Token"]).toBe("tok123");
    expect(headers["Idempotency-Key"]).toBe("k1");
  });

  it("marks polling reads so the server can skip their log line", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(json({}, 200));
    await createClient("/dashboard/api").get("/payments/p1", { poll: true });
    expect((fetchMock.mock.calls[0][1]!.headers as Record<string, string>)["X-Poll"]).toBe("1");
  });

  it("turns the error envelope into an ApiFailure", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(json({ error: { code: "forbidden", message: "no", retriable: false } }, 403));
    await expect(createClient("/dashboard/api").get("/x")).rejects.toMatchObject({ status: 403, code: "forbidden" });
  });

  it("on step_up_required asks the handler, then retries once with the same key", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(json({ error: { code: "step_up_required", message: "" } }, 401))
      .mockResolvedValueOnce(json({}, 200));
    const api = createClient("/dashboard/api");
    api.onStepUp(async () => true);
    await api.post("/api_keys", { name: "x" }, { idempotencyKey: "same" });
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect((fetchMock.mock.calls[1][1]!.headers as Record<string, string>)["Idempotency-Key"]).toBe("same");
  });

  it("gives up if the user cancels the step-up", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(json({ error: { code: "step_up_required", message: "" } }, 401));
    const api = createClient("/dashboard/api");
    api.onStepUp(async () => false);
    await expect(api.post("/api_keys", {})).rejects.toMatchObject({ code: "step_up_required" });
  });

  it("calls the sign-in handler on a plain 401", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(json({ error: { code: "unauthenticated", message: "" } }, 401));
    const api = createClient("/dashboard/api");
    const onSignIn = vi.fn();
    api.onUnauthenticated(onSignIn);
    await expect(api.get("/me")).rejects.toBeInstanceOf(ApiFailure);
    expect(onSignIn).toHaveBeenCalled();
  });

  it("returns undefined for 204", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(null, { status: 204 }));
    await expect(createClient("/dashboard/api").delete("/session")).resolves.toBeUndefined();
  });
});
