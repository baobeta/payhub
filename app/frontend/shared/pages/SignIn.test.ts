import { describe, expect, it, vi } from "vitest";
import { flushPromises, mount } from "@vue/test-utils";
import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import { createMemoryHistory, createRouter } from "vue-router";
import SignIn from "./SignIn.vue";
import type { ApiClient } from "../http";

async function signInWith(answer: unknown) {
  const client = { post: vi.fn().mockResolvedValue(answer) };
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: "/:p(.*)*", component: { template: "<div />" } }],
  });
  await router.push("/sign-in");
  const w = mount(SignIn, {
    props: { client: client as unknown as ApiClient },
    global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
  await w.get('input[type="email"]').setValue("dev@example.com");
  await w.get('input[type="password"]').setValue("correct horse battery staple");
  await w.get("form").trigger("submit");
  await flushPromises();
  return { w, router };
}

describe("SignIn", () => {
  it("asks for the code after the password", async () => {
    const { w } = await signInWith({ otp_required: true });
    expect(w.text()).toContain("Authenticator code");
  });

  it("TC-M12-3 sends someone whose authenticator was reset to enrol a new one", async () => {
    const { router } = await signInWith({ next: "enrol_otp" });
    expect(router.currentRoute.value.path).toBe("/enrol");
  });
});
