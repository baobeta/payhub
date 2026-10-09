<script setup lang="ts">
import { computed, provide } from "vue";
import { useRoute } from "vue-router";
import { createClient } from "../../shared/http";
import { useMe } from "../useMe";
import { AREA_BASE, AREA_CLIENT, AREA_ME, type AreaMe } from "../../shared/area";
import type { Permission } from "../../shared/can";

const route = useRoute();
const merchantId = computed(() => String(route.params.merchantId));
const client = createClient(`/ops/api/as/${merchantId.value}`);
const { data: me } = useMe();

// The server fakes every merchant permission down to `.read` under the `as/`
// scope, so the reused merchant pages can only read. `payments.export` is not
// a `.read`, so exports stay hidden here (Pages also gate on `impersonating`).
const IMPERSONATION_PERMISSIONS: Permission[] = [
  "payments.read", "balance.read", "settlements.read", "api_keys.read",
  "webhooks.read", "team.read", "security_history.read",
];

const areaMe = computed<AreaMe | null>(() => {
  const info = me.value?.impersonating;
  if (!info || info.merchant_id !== merchantId.value) return null;
  return {
    user: me.value!.user,
    merchant: { id: info.merchant_id, name: info.merchant_name ?? "Merchant" },
    livemode: true, // impersonation always shows the live merchant
    permissions: IMPERSONATION_PERMISSIONS,
    impersonating: true,
  };
});

provide(AREA_CLIENT, client);
provide(AREA_ME, areaMe);
provide(AREA_BASE, `/as/${merchantId.value}`);

const nav = [
  { to: "", label: "Home" },
  { to: "payments", label: "Payments" },
  { to: "balance", label: "Balance" },
  { to: "api-keys", label: "API keys" },
  { to: "webhooks", label: "Webhooks" },
  { to: "events", label: "Events" },
  { to: "team", label: "Team" },
  { to: "security", label: "Security history" },
];
</script>

<template>
  <div
    v-if="areaMe"
    class="space-y-4"
  >
    <nav
      class="flex flex-wrap gap-2 text-sm"
      aria-label="Merchant sections"
    >
      <RouterLink
        v-for="item in nav"
        :key="item.to"
        :to="`/as/${merchantId}/${item.to}`"
        class="rounded border border-slate-200 bg-white px-3 py-1.5 hover:bg-slate-100"
        active-class="bg-slate-100 font-medium"
        :exact-active-class="item.to === '' ? 'bg-slate-100 font-medium' : undefined"
      >
        {{ item.label }}
      </RouterLink>
    </nav>
    <RouterView />
  </div>
  <p
    v-else
    role="alert"
  >
    This impersonation has ended or belongs to another operator.
  </p>
</template>
