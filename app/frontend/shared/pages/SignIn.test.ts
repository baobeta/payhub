import { describe, expect, it, vi } from "vitest";
import { flushPromises, mount } from "@vue/test-utils";
import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import { createMemoryHistory, createRouter } from "vue-router";
import SignIn from "./SignIn.vue";
import type { ApiClient } from "../http";

async function signInWith(answer: unknown, props: { resetToken?: string } = {}) {
  const client = { post: vi.fn().mockResolvedValue(answer) };
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: "/:p(.*)*", component: { template: "<div />" } }],
  });
  await router.push("/sign-in");
  const w = mount(SignIn, {
    props: { client: client as unknown as ApiClient, ...props },
    global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
  await w.get('input[type="email"]').setValue("dev@example.com");
  await w.get('input[type="password"]').setValue("correct horse battery staple");
  await w.get("form").trigger("submit");
  await flushPromises();
  return { w, router, client };
}

describe("SignIn", () => {
  it("asks for the code after the password", async () => {
    const { w, client } = await signInWith({ otp_required: true });
    expect(w.text()).toContain("Authenticator code");
    expect(client.post).toHaveBeenCalledWith("/session", { email: "dev@example.com", password: "correct horse battery staple" });
  });

  it("TC-M12-3 sends someone whose authenticator was reset to enrol a new one", async () => {
    const { router } = await signInWith({ next: "enrol_otp" });
    expect(router.currentRoute.value.path).toBe("/enrol");
  });

  it("TC-M12-5 sends the reset link's token with the password, then enrols a new authenticator", async () => {
    const { w, router, client } = await signInWith({ next: "enrol_otp" }, { resetToken: "tok-123" });
    expect(w.text()).toContain("Set up a new authenticator");
    expect(client.post).toHaveBeenCalledWith("/session", {
      email: "dev@example.com", password: "correct horse battery staple", reset_token: "tok-123",
    });
    expect(router.currentRoute.value.path).toBe("/enrol");
  });
});
