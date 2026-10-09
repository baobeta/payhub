import { describe, expect, it, vi } from "vitest";
import { flushPromises, mount } from "@vue/test-utils";
import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import { createMemoryHistory, createRouter } from "vue-router";
import ProposalDetail from "./ProposalDetail.vue";
import type { Proposal } from "../types";

const get = vi.fn();
vi.mock("../api", () => ({ api: { get: (...a: unknown[]) => get(...a), post: vi.fn(), delete: vi.fn(), put: vi.fn() } }));

function proposal(overrides: Partial<Proposal> = {}): Proposal {
  return {
    id: "p1",
    kind: "payment_transition",
    payment_id: "pay1",
    merchant: "Acme",
    payload: { to_state: "failed" },
    reason_code: "psp_confirmed_outcome",
    reason_text: "PSP said it failed",
    case_reference: "OPS-42",
    state: "pending",
    proposed_by: "ops@example.com",
    decided_by: null,
    decision_note: null,
    created_at: "2026-01-01T00:00:00Z",
    decided_at: null,
    applied_at: null,
    applied_transfer_id: null,
    error: null,
    can: { approve: false, reject: false, withdraw: true },
    ...overrides,
  };
}

async function render(p: Proposal) {
  get.mockImplementation((path: string) =>
    Promise.resolve(path === "/proposals"
      ? { data: [p] }
      : { state: "unknown", psp_calls: [], payment_id: p.payment_id }));
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [
      { path: "/proposals/:id", component: ProposalDetail },
      { path: "/:p(.*)*", component: { template: "<div />" } },
    ],
  });
  await router.push("/proposals/p1");
  await router.isReady();
  const w = mount(ProposalDetail, { global: { plugins: [router, [VueQueryPlugin, { queryClient }]] } });
  await flushPromises();
  return w;
}

describe("ProposalDetail", () => {
  it("hides Approve when can.approve is false", async () => {
    const text = (await render(proposal())).text();
    expect(text).not.toContain("Approve");
    expect(text).toContain("Withdraw");
  });

  it("shows Approve when can.approve is true", async () => {
    const text = (await render(proposal({ can: { approve: true, reject: true, withdraw: false } }))).text();
    expect(text).toContain("Approve");
    expect(text).toContain("Reject");
  });
});
