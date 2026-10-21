import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { flushPromises, mount } from "@vue/test-utils";
import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import Team from "./Team.vue";
import type { Me } from "../types";

const get = vi.fn();
const post = vi.fn();
vi.mock("../api", () => ({
  api: { get: (...a: unknown[]) => get(...a), post: (...a: unknown[]) => post(...a), patch: vi.fn(), delete: vi.fn() },
}));

const admin: Me = {
  user: { id: "u-admin", email: "admin@example.com", name: "A", role: "admin" },
  merchant: { id: "m1", name: "Acme" },
  livemode: true,
  stepped_up_until: null,
  permissions: ["team.read", "team.manage"],
};

const members = [
  { id: "u-owner", email: "owner@example.com", name: "O", role: "owner", status: "active", invitation_expires_at: null },
  { id: "u-admin", email: "admin@example.com", name: "A", role: "admin", status: "active", invitation_expires_at: null },
  { id: "u-dev", email: "dev@example.com", name: "D", role: "developer", status: "active", invitation_expires_at: null },
  { id: "u-new", email: "new@example.com", name: null, role: "viewer", status: "invited", invitation_expires_at: "2026-10-31T00:00:00Z" },
];

async function render(me: Me = admin) {
  const queryClient = new QueryClient();
  queryClient.setQueryData(["me"], me);
  get.mockImplementation(async (path: string) => (path === "/me" ? me : { data: members }));
  const w = mount(Team, { global: { plugins: [[VueQueryPlugin, { queryClient }]] }, attachTo: document.body });
  await flushPromises();
  return w;
}

const row = (w: Awaited<ReturnType<typeof render>>, email: string) => w.findAll("tbody tr").find((r) => r.text().includes(email))!;
// Reka UI teleports dialogs to <body>, so query the document, not the wrapper.
const $ = <T extends Element>(sel: string) => document.body.querySelector<T>(sel)!;

describe("Team", () => {
  beforeEach(() => {
    get.mockReset();
    post.mockReset();
  });
  afterEach(() => {
    document.body.innerHTML = "";
  });

  it("TC-M11-1 offers Resend only on pending invitations, and resends", async () => {
    post.mockResolvedValue({});
    const w = await render();
    expect(row(w, "dev@example.com").text()).not.toContain("Resend");
    await row(w, "new@example.com").get('[data-testid="resend"]').trigger("click");
    await flushPromises();
    expect(post).toHaveBeenCalledWith("/invitations/u-new/resend");
    expect(w.text()).toContain("Invitation sent again to new@example.com");
    w.unmount();
  });

  it("TC-M12-4 offers Reset authenticator on other active members, never the owner or yourself", async () => {
    const w = await render();
    expect(row(w, "dev@example.com").find('[data-testid="reset-otp"]').exists()).toBe(true);
    expect(row(w, "owner@example.com").find('[data-testid="reset-otp"]').exists()).toBe(false);
    expect(row(w, "admin@example.com").find('[data-testid="reset-otp"]').exists()).toBe(false);
    expect(row(w, "new@example.com").find('[data-testid="reset-otp"]').exists()).toBe(false);
    w.unmount();
  });

  it("TC-M12-3 resets an authenticator after confirming", async () => {
    post.mockResolvedValue({});
    const w = await render();
    await row(w, "dev@example.com").get('[data-testid="reset-otp"]').trigger("click");
    await flushPromises();
    $<HTMLFormElement>("form").dispatchEvent(new Event("submit"));
    await flushPromises();
    expect(post).toHaveBeenCalledWith("/members/u-dev/reset_otp");
    w.unmount();
  });

  it("hides both actions without team.manage", async () => {
    const w = await render({ ...admin, permissions: ["team.read"] });
    expect(w.find('[data-testid="resend"]').exists()).toBe(false);
    expect(w.find('[data-testid="reset-otp"]').exists()).toBe(false);
    w.unmount();
  });
});
