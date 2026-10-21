import { describe, expect, it, vi } from "vitest";
import { flushPromises, mount } from "@vue/test-utils";
import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import { createMemoryHistory, createRouter } from "vue-router";
import ResetAuthenticator from "./ResetAuthenticator.vue";

const post = vi.fn();
vi.mock("../api", () => ({ api: { post: (...a: unknown[]) => post(...a) } }));

describe("ResetAuthenticator", () => {
  it("TC-M12-5 takes the token from the emailed link and sends it with the password", async () => {
    post.mockResolvedValue({ next: "enrol_otp" });
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [{ path: "/:p(.*)*", component: { template: "<div />" } }],
    });
    await router.push("/reset-authenticator?token=tok-from-email");
    const w = mount(ResetAuthenticator, {
      global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
    });

    await w.get('input[type="email"]').setValue("dev@example.com");
    await w.get('input[type="password"]').setValue("correct horse battery staple");
    await w.get("form").trigger("submit");
    await flushPromises();

    expect(post).toHaveBeenCalledWith("/session", {
      email: "dev@example.com", password: "correct horse battery staple", reset_token: "tok-from-email",
    });
    expect(router.currentRoute.value.path).toBe("/enrol");
  });
});
