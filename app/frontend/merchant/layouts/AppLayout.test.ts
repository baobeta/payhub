import { describe, expect, it, vi } from "vitest";
import { flushPromises, mount } from "@vue/test-utils";
import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import { createMemoryHistory, createRouter } from "vue-router";
import AppLayout from "./AppLayout.vue";
import type { Me } from "../types";

const put = vi.fn();
vi.mock("../api", () => ({ api: { get: vi.fn(), put: (...a: unknown[]) => put(...a), delete: vi.fn(), post: vi.fn() } }));

function me(overrides: Partial<Me> = {}): Me {
  return {
    user: { id: "u1", email: "v@example.com", name: "V", role: "viewer" },
    merchant: { id: "m1", name: "Acme" },
    livemode: true,
    stepped_up_until: null,
    permissions: ["payments.read", "payments.export", "balance.read", "settlements.read"],
    ...overrides,
  };
}

async function render(data: Me) {
  const queryClient = new QueryClient();
  queryClient.setQueryData(["me"], data);
  const router = createRouter({ history: createMemoryHistory(), routes: [{ path: "/:p(.*)*", component: { template: "<div />" } }] });
  const w = mount(AppLayout, { global: { plugins: [router, [VueQueryPlugin, { queryClient }]] } });
  await flushPromises();
  return w;
}

describe("AppLayout", () => {
  it("shows a viewer the money pages but not developers or team", async () => {
    const nav = (await render(me())).find('nav[aria-label="Main"]').text();
    expect(nav).toContain("Payments");
    expect(nav).toContain("Balance");
    expect(nav).not.toContain("API keys");
    expect(nav).not.toContain("Team");
  });

  it("shows the test-mode banner only in test mode", async () => {
    expect((await render(me())).find('[data-testid="test-mode-banner"]').exists()).toBe(false);
    expect((await render(me({ livemode: false }))).find('[data-testid="test-mode-banner"]').exists()).toBe(true);
  });

  it("switching to test mode shows the banner at once", async () => {
    put.mockResolvedValue(me({ livemode: false }));
    const w = await render(me());
    await w.get('button[aria-pressed="false"]').trigger("click");
    await flushPromises();
    expect(put).toHaveBeenCalledWith("/mode", { livemode: false });
    expect(w.find('[data-testid="test-mode-banner"]').exists()).toBe(true);
  });
});
