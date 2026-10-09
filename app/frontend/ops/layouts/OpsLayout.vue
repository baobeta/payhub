<script setup lang="ts">
import { computed } from "vue";
import { useQueryClient } from "@tanstack/vue-query";
import { useRouter } from "vue-router";
import { api } from "../api";
import { useMe } from "../useMe";
import { ApiFailure } from "../../shared/http";
import StepUpDialog from "../../shared/components/StepUpDialog.vue";
import type { Permission } from "../../shared/can";
import type { OpsMe } from "../types";
import { ref } from "vue";

const { data: me, allowed } = useMe();
const queryClient = useQueryClient();
const router = useRouter();

const NAV: { to: string; label: string; permission: Permission }[] = [
  { to: "/", label: "Queue", permission: "ops.queue.read" },
  { to: "/search", label: "Search", permission: "ops.payments.read" },
  { to: "/proposals", label: "Proposals", permission: "ops.payments.read" },
  { to: "/circuits", label: "PSP circuits", permission: "ops.circuits.read" },
  { to: "/reconciliation", label: "Reconciliation", permission: "ops.reconciliation.read" },
  { to: "/operators", label: "Operators", permission: "ops.operators.manage" },
  { to: "/audit", label: "Audit", permission: "ops.audit.read" },
];
const nav = computed(() => NAV.filter((n) => allowed(n.permission)));

const endError = ref<string | null>(null);

function endsAt(): string {
  const exp = me.value?.impersonating?.expires_at;
  return exp ? new Date(exp).toLocaleTimeString() : "";
}

async function endImpersonation() {
  endError.value = null;
  try {
    await api.delete("/impersonations/current");
    queryClient.setQueryData<OpsMe>(["me"], (old) => (old ? { ...old, impersonating: null } : old));
    router.push({ name: "queue" });
  } catch (e) {
    endError.value = e instanceof ApiFailure ? e.message : "Could not end the session. Try again.";
  }
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
      v-if="me.impersonating"
      class="fixed inset-x-0 top-0 z-50 flex items-center gap-3 bg-red-700 px-4 py-2 text-sm font-medium text-white"
      data-testid="impersonation-banner"
      role="status"
    >
      <span>
        Viewing <strong>{{ me.impersonating.merchant_name ?? me.impersonating.merchant_id }}</strong>
        as PayHub support, read-only, ends at {{ endsAt() }}.
      </span>
      <span
        v-if="endError"
        class="text-red-100"
      >{{ endError }}</span>
      <button
        type="button"
        class="ml-auto rounded bg-white/20 px-2 py-0.5"
        @click="endImpersonation"
      >
        End
      </button>
    </div>
    <header
      class="flex items-center gap-4 border-b border-slate-200 bg-white px-6 py-3"
      :class="me.impersonating ? 'mt-9' : ''"
    >
      <span class="font-semibold">PayHub operations</span>
      <span class="ml-auto text-sm text-slate-600">{{ me.user.email }} · {{ me.user.role }}</span>
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
