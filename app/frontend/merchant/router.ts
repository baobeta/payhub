import { createRouter, createWebHistory } from "vue-router";
import type { Permission } from "../shared/can";

declare module "vue-router" {
  interface RouteMeta {
    public?: boolean;
    permission?: Permission;
  }
}

// History mode under /dashboard; Rails serves the shell for any path below it.
export const router = createRouter({
  history: createWebHistory("/dashboard"),
  routes: [
    { path: "/sign-in", name: "sign-in", component: () => import("./pages/SignIn.vue"), meta: { public: true } },
    { path: "/invitations/:token", name: "invitation", component: () => import("./pages/AcceptInvitation.vue"), meta: { public: true } },
    { path: "/enrol", name: "enrol", component: () => import("./pages/EnrolOtp.vue"), meta: { public: true } },
    {
      path: "/",
      component: () => import("./layouts/AppLayout.vue"),
      children: [
        { path: "", name: "home", component: () => import("./pages/Home.vue"), meta: { permission: "payments.read" } },
        { path: "payments", name: "payments", component: () => import("./pages/Payments.vue"), meta: { permission: "payments.read" } },
        { path: "payments/:id", name: "payment", component: () => import("./pages/PaymentDetail.vue"), meta: { permission: "payments.read" } },
        { path: "balance", name: "balance", component: () => import("./pages/Balance.vue"), meta: { permission: "balance.read" } },
        { path: "developers/api-keys", name: "api-keys", component: () => import("./pages/ApiKeys.vue"), meta: { permission: "api_keys.read" } },
        { path: "developers/webhooks", name: "webhooks", component: () => import("./pages/Webhooks.vue"), meta: { permission: "webhooks.read" } },
        { path: "developers/events", name: "events", component: () => import("./pages/Events.vue"), meta: { permission: "webhooks.read" } },
        { path: "team", name: "team", component: () => import("./pages/Team.vue"), meta: { permission: "team.read" } },
        { path: "security", name: "security", component: () => import("./pages/SecurityHistory.vue"), meta: { permission: "security_history.read" } },
        { path: "profile", name: "profile", component: () => import("./pages/Profile.vue") },
      ],
    },
    { path: "/:rest(.*)*", name: "not-found", component: () => import("./pages/NotFound.vue"), meta: { public: true } },
  ],
});
