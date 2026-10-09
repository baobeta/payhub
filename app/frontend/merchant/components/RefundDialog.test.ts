import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { flushPromises, mount } from "@vue/test-utils";
import RefundDialog from "./RefundDialog.vue";
import { ApiFailure } from "../../shared/http";

const post = vi.fn();
vi.mock("../api", () => ({ api: { post: (...args: unknown[]) => post(...args) } }));

function mountDialog(open = true) {
  return mount(RefundDialog, {
    props: { open, paymentId: "p1", currency: "EUR", refundableMinor: 2500 },
    attachTo: document.body,
  });
}

// Reka UI teleports dialogs to <body>, so query the document, not the wrapper.
const $ = <T extends Element>(sel: string) => document.body.querySelector<T>(sel)!;

async function submitWith(reason: string) {
  const select = $<HTMLSelectElement>('[data-testid="refund-reason"]');
  select.value = reason;
  select.dispatchEvent(new Event("change"));
  await flushPromises();
  $<HTMLButtonElement>('[data-testid="refund-submit"]').click();
  await flushPromises();
}

describe("RefundDialog", () => {
  beforeEach(() => post.mockReset());
  afterEach(() => {
    document.body.innerHTML = "";
  });

  it("prefills the refundable amount and needs a reason", async () => {
    const w = mountDialog();
    await flushPromises();
    expect($<HTMLInputElement>('[data-testid="refund-amount"]').value).toBe("25.00");
    expect($<HTMLButtonElement>('[data-testid="refund-submit"]').disabled).toBe(true);
    w.unmount();
  });

  it("retries a failed submit with the same idempotency key", async () => {
    post.mockRejectedValueOnce(new ApiFailure(503, "psp_unavailable", "try again", true)).mockResolvedValueOnce({});
    const w = mountDialog();
    await flushPromises();
    await submitWith("duplicate");
    $<HTMLButtonElement>('[data-testid="refund-submit"]').click();
    await flushPromises();
    expect(post).toHaveBeenCalledTimes(2);
    expect(post.mock.calls[0][2].idempotencyKey).toBe(post.mock.calls[1][2].idempotencyKey);
    expect(post.mock.calls[0][1]).toEqual({ amount_minor: 2500, reason: "duplicate" });
    w.unmount();
  });

  it("uses a new key when the dialog is opened again", async () => {
    post.mockResolvedValue({});
    const w = mountDialog();
    await flushPromises();
    await submitWith("other");
    await w.setProps({ open: false });
    await w.setProps({ open: true });
    await flushPromises();
    await submitWith("other");
    expect(post.mock.calls[0][2].idempotencyKey).not.toBe(post.mock.calls[1][2].idempotencyKey);
    w.unmount();
  });
});
