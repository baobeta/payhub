import { describe, expect, it, vi } from "vitest";
import { flushPromises, mount } from "@vue/test-utils";
import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import SessionsList from "./SessionsList.vue";
import type { ApiClient } from "../http";

const rows = [
  { id: "s1", browser: "Firefox", os: "macOS", ip: "1.2.3.4", created_at: "2026-10-21T08:00:00Z", last_active_at: "2026-10-21T09:00:00Z", current: true },
  { id: "s2", browser: "Chrome", os: "Windows", ip: "5.6.7.8", created_at: "2026-10-20T08:00:00Z", last_active_at: "2026-10-20T09:00:00Z", current: false },
];

function render() {
  const client = {
    get: vi.fn().mockResolvedValue({ data: rows }),
    delete: vi.fn().mockResolvedValue(undefined),
    post: vi.fn().mockResolvedValue({ revoked: 1 }),
  };
  const w = mount(SessionsList, {
    props: { client: client as unknown as ApiClient },
    global: { plugins: [[VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
  return { w, client };
}

describe("SessionsList", () => {
  it("TC-M7-1 lists sessions and offers sign-out only for the other ones", async () => {
    const { w } = render();
    await flushPromises();
    const items = w.findAll('[data-testid="session-row"]');
    expect(items).toHaveLength(2);
    expect(items[0].text()).toContain("This browser");
    expect(items[0].find("button").exists()).toBe(false);
    expect(items[1].text()).toContain("Chrome on Windows");
    expect(items[1].find("button").exists()).toBe(true);
  });

  it("TC-M7-2 signs out one session and refreshes the list", async () => {
    const { w, client } = render();
    await flushPromises();
    await w.get('button[aria-label="Sign out Chrome on Windows"]').trigger("click");
    await flushPromises();
    expect(client.delete).toHaveBeenCalledWith("/sessions/s2");
    expect(client.get).toHaveBeenCalledTimes(2);
    expect(w.text()).toContain("Signed out Chrome on Windows.");
  });

  it("TC-M7-4 signs out all other sessions", async () => {
    const { w, client } = render();
    await flushPromises();
    await w.get('[data-testid="revoke-others"]').trigger("click");
    await flushPromises();
    expect(client.post).toHaveBeenCalledWith("/sessions/revoke_others");
    expect(w.text()).toContain("Signed out 1 other session.");
  });
});
