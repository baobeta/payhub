import { describe, expect, it, vi } from "vitest";
import { flushPromises, mount } from "@vue/test-utils";
import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import { createMemoryHistory, createRouter } from "vue-router";
import OpsLayout from "./OpsLayout.vue";
import type { OpsMe } from "../types";

vi.mock("../api", () => ({ api: { get: vi.fn(), put: vi.fn(), delete: vi.fn(), post: vi.fn() } }));

function me(overrides: Partial<OpsMe> = {}): OpsMe {
  return {
    user: { id: "o1", email: "ops@example.com", name: "O", role: "ops" },
    stepped_up_until: null,
    permissions: ["ops.queue.read", "ops.payments.read"],
    impersonating: null,
    ...overrides,
  };
}

async function render(data: OpsMe) {
  const queryClient = new QueryClient();
  queryClient.setQueryData(["me"], data);
  const router = createRouter({ history: createMemoryHistory(), routes: [{ path: "/:p(.*)*", component: { template: "<div />" } }] });
  const w = mount(OpsLayout, { global: { plugins: [router, [VueQueryPlugin, { queryClient }]] } });
  await flushPromises();
  return w;
}

describe("OpsLayout", () => {
  it("shows the impersonation banner when me.impersonating is set", async () => {
    const banner = (await render(me({
      impersonating: { merchant_id: "m1", merchant_name: "Acme", case_ref: "OPS-42", expires_at: "2026-01-01T00:30:00Z" },
    }))).find('[data-testid="impersonation-banner"]');
    expect(banner.exists()).toBe(true);
    expect(banner.text()).toContain("Acme");
    expect(banner.text()).toContain("read-only");
  });

  it("shows no banner when not impersonating", async () => {
    expect((await render(me())).find('[data-testid="impersonation-banner"]').exists()).toBe(false);
  });
});
