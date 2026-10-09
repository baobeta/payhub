<script setup lang="ts">
import { computed } from "vue";
import { useQueryClient } from "@tanstack/vue-query";
import { useRouter } from "vue-router";
import { api } from "../api";
import { useMe } from "../useMe";
import StepUpDialog from "../../shared/components/StepUpDialog.vue";
import type { Permission } from "../../shared/can";
import type { Me } from "../types";

const { data: me, allowed } = useMe();
const queryClient = useQueryClient();
const router = useRouter();

const NAV: { to: string; label: string; permission: Permission }[] = [
  { to: "/", label: "Home", permission: "payments.read" },
  { to: "/payments", label: "Payments", permission: "payments.read" },
  { to: "/balance", label: "Balance", permission: "balance.read" },
  { to: "/developers/api-keys", label: "API keys", permission: "api_keys.read" },
  { to: "/developers/webhooks", label: "Webhooks", permission: "webhooks.read" },
  { to: "/developers/events", label: "Events", permission: "webhooks.read" },
  { to: "/team", label: "Team", permission: "team.read" },
  { to: "/security", label: "Security history", permission: "security_history.read" },
];
const nav = computed(() => NAV.filter((n) => allowed(n.permission)));

async function setMode(livemode: boolean) {
  const updated = await api.put<Me>("/mode", { livemode });
  queryClient.setQueryData(["me"], updated);
  // Every other cached page belongs to the old mode. reset (not remove) keeps
  // mounted pages subscribed, clears their data and refetches them.
  await queryClient.resetQueries({ predicate: (q) => q.queryKey[0] !== "me" });
}

async function signOut() {
  await api.delete("/session");
  queryClient.clear();
  router.push({ name: "sign-in" });
}
</script>

<template>
  <div
    v-if="me"
    class="min-h-screen bg-slate-50 text-slate-900"
  >
    <div
      v-if="!me.livemode"
      class="bg-amber-400 px-4 py-1 text-center text-sm font-medium text-amber-950"
      data-testid="test-mode-banner"
    >
      Test mode: you are looking at test data.
    </div>
    <header class="flex items-center gap-4 border-b border-slate-200 bg-white px-6 py-3">
      <span class="font-semibold">{{ me.merchant.name }}</span>
      <div
        class="flex overflow-hidden rounded border border-slate-300 text-sm"
        role="group"
        aria-label="Data mode"
      >
        <button
          type="button"
          class="px-2 py-1"
          :class="me.livemode ? 'bg-slate-900 text-white' : ''"
          :aria-pressed="me.livemode"
          @click="setMode(true)"
        >
          Live
        </button>
        <button
          type="button"
          class="px-2 py-1"
          :class="!me.livemode ? 'bg-amber-400 text-amber-950' : ''"
          :aria-pressed="!me.livemode"
          @click="setMode(false)"
        >
          Test
        </button>
      </div>
      <span class="ml-auto text-sm text-slate-600">{{ me.user.email }} · {{ me.user.role }}</span>
      <RouterLink
        to="/profile"
        class="text-sm underline"
      >
        Profile
      </RouterLink>
      <button
        type="button"
        class="text-sm underline"
        @click="signOut"
      >
        Sign out
      </button>
    </header>
    <div class="flex">
      <nav
        class="w-52 shrink-0 border-r border-slate-200 bg-white p-3"
        aria-label="Main"
      >
        <RouterLink
          v-for="item in nav"
          :key="item.to"
          :to="item.to"
          class="block rounded px-3 py-2 text-sm hover:bg-slate-100"
          active-class="bg-slate-100 font-medium"
          :exact-active-class="item.to === '/' ? 'bg-slate-100 font-medium' : undefined"
        >
          {{ item.label }}
        </RouterLink>
      </nav>
      <main class="min-w-0 flex-1 p-6">
        <RouterView />
      </main>
    </div>
    <StepUpDialog :client="api" />
  </div>
</template>
