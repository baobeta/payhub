import { createRouter, createWebHistory } from "vue-router";
import type { Permission } from "../shared/can";

declare module "vue-router" {
  interface RouteMeta {
    public?: boolean;
    permission?: Permission;
  }
}

// History mode under /ops; Rails serves the shell for any path below it.
export const router = createRouter({
  history: createWebHistory("/ops"),
  routes: [
    { path: "/sign-in", name: "sign-in", component: () => import("./pages/SignIn.vue"), meta: { public: true } },
    { path: "/invitations/:token", name: "invitation", component: () => import("./pages/AcceptInvitation.vue"), meta: { public: true } },
    { path: "/enrol", name: "enrol", component: () => import("./pages/EnrolOtp.vue"), meta: { public: true } },
    {
      path: "/",
      component: () => import("./layouts/OpsLayout.vue"),
      children: [
        { path: "", name: "queue", component: () => import("./pages/Queue.vue"), meta: { permission: "ops.queue.read" } },
        { path: "search", name: "search", component: () => import("./pages/Search.vue"), meta: { permission: "ops.payments.read" } },
        { path: "payments/:id", name: "payment", component: () => import("./pages/PaymentDetail.vue"), meta: { permission: "ops.payments.read" } },
        { path: "proposals", name: "proposals", component: () => import("./pages/Proposals.vue"), meta: { permission: "ops.payments.read" } },
        { path: "proposals/:id", name: "proposal", component: () => import("./pages/ProposalDetail.vue"), meta: { permission: "ops.payments.read" } },
        { path: "circuits", name: "circuits", component: () => import("./pages/Circuits.vue"), meta: { permission: "ops.circuits.read" } },
        { path: "reconciliation", name: "reconciliation", component: () => import("./pages/Reconciliation.vue"), meta: { permission: "ops.reconciliation.read" } },
        { path: "operators", name: "operators", component: () => import("./pages/Operators.vue"), meta: { permission: "ops.operators.manage" } },
        { path: "audit", name: "audit", component: () => import("./pages/Audit.vue"), meta: { permission: "ops.audit.read" } },
        {
          path: "as/:merchantId",
          component: () => import("./pages/ImpersonationView.vue"),
          meta: { permission: "ops.payments.read" },
          children: [
            { path: "", name: "as-home", component: () => import("../merchant/pages/Home.vue") },
            { path: "payments", name: "as-payments", component: () => import("../merchant/pages/Payments.vue") },
            { path: "payments/:id", name: "as-payment", component: () => import("../merchant/pages/PaymentDetail.vue") },
            { path: "balance", name: "as-balance", component: () => import("../merchant/pages/Balance.vue") },
            { path: "events", name: "as-events", component: () => import("../merchant/pages/Events.vue") },
            { path: "api-keys", name: "as-api-keys", component: () => import("../merchant/pages/ApiKeys.vue") },
            { path: "webhooks", name: "as-webhooks", component: () => import("../merchant/pages/Webhooks.vue") },
            { path: "team", name: "as-team", component: () => import("../merchant/pages/Team.vue") },
            { path: "security", name: "as-security", component: () => import("../merchant/pages/SecurityHistory.vue") },
          ],
        },
      ],
    },
    { path: "/:rest(.*)*", name: "not-found", component: () => import("./pages/NotFound.vue"), meta: { public: true } },
  ],
});
