import { describe, expect, it, vi } from "vitest";
import { flushPromises, mount } from "@vue/test-utils";
import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import { createMemoryHistory, createRouter } from "vue-router";
import Queue from "./Queue.vue";
import type { Queue as QueueData } from "../types";

const get = vi.fn();
vi.mock("../api", () => ({ api: { get: (...a: unknown[]) => get(...a) } }));

function queue(overrides: Partial<QueueData> = {}): QueueData {
  return {
    unknown_payments: [],
    stuck_pending: [],
    late_successes: [],
    dead_events: [],
    reconciliation_breaks: 0,
    open_proposals: 0,
    ...overrides,
  };
}

async function render(data: QueueData) {
  get.mockResolvedValue(data);
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const router = createRouter({ history: createMemoryHistory(), routes: [{ path: "/:p(.*)*", component: { template: "<div />" } }] });
  await router.push("/");
  await router.isReady();
  const w = mount(Queue, { global: { plugins: [router, [VueQueryPlugin, { queryClient }]] } });
  await flushPromises();
  return w;
}

describe("Queue", () => {
  it("TC-C6-1: lists payments pending for over 15 minutes", async () => {
    const text = (await render(queue({
      stuck_pending: [{
        id: "pay1", merchant: "Acme", psp_name: "nordpay", psp_reference: "ph_stuck", amount_minor: 2500,
        currency: "EUR", pending_since: new Date(Date.now() - 20 * 60_000).toISOString(), check_attempts: 3,
      }],
    }))).text();
    expect(text).toContain("Pending for over 15 minutes");
    expect(text).toContain("ph_stuck");
    expect(text).toContain("20m");
  });

  it("TC-C6-1: hides the section when nothing is stuck in pending", async () => {
    expect((await render(queue())).text()).not.toContain("Pending for over 15 minutes");
  });
});
