<script setup lang="ts">
import { ref } from "vue";
import { useQuery } from "@tanstack/vue-query";
import { api } from "../api";
import { useMe } from "../useMe";
import { formatMoney } from "../../shared/money";
import StatusBadge from "../../shared/components/StatusBadge.vue";
import ImpersonationDialog from "../components/ImpersonationDialog.vue";
import type { List, SearchRow } from "../types";

const { allowed } = useMe();
const q = ref("");
const submitted = ref("");

const results = useQuery({
  queryKey: ["ops-search", submitted],
  enabled: () => submitted.value.length >= 2,
  queryFn: () => api.get<List<SearchRow>>(`/payments?q=${encodeURIComponent(submitted.value)}`),
});

const target = ref<SearchRow | null>(null);

function search() {
  submitted.value = q.value.trim();
}
</script>

<template>
  <div class="space-y-4">
    <h1 class="text-2xl font-semibold">
      Search
    </h1>
    <form
      class="flex gap-2"
      @submit.prevent="search"
    >
      <input
        v-model="q"
        placeholder="Payment id, ph_ reference, or merchant name"
        class="w-full max-w-lg rounded border border-slate-300 px-3 py-2"
        aria-label="Search payments"
      >
      <button
        type="submit"
        class="rounded bg-slate-900 px-4 py-2 text-white"
      >
        Search
      </button>
    </form>
    <p class="text-sm text-slate-500">
      Matches an exact payment id, an exact <code>ph_</code> reference, or a merchant name prefix.
    </p>

    <table
      v-if="results.data.value"
      class="w-full rounded bg-white text-sm shadow-sm"
    >
      <thead class="text-left text-slate-500">
        <tr>
          <th class="p-2">
            Merchant
          </th><th class="p-2">
            Amount
          </th><th class="p-2">
            State
          </th><th class="p-2">
            Reference
          </th><th class="p-2" />
        </tr>
      </thead>
      <tbody>
        <tr
          v-for="p in results.data.value.data"
          :key="p.id"
          class="border-t border-slate-100"
        >
          <td class="p-2">
            {{ p.merchant }}
            <span
              class="ml-1 text-xs text-slate-500"
            >{{ p.livemode ? "live" : "test" }}</span>
          </td>
          <td class="p-2">
            {{ formatMoney(p.amount_minor, p.currency) }}
          </td>
          <td class="p-2">
            <StatusBadge :status="p.state" />
          </td>
          <td class="p-2 font-mono text-xs">
            {{ p.psp_reference }}
          </td>
          <td class="p-2 text-right">
            <RouterLink
              :to="`/payments/${p.id}`"
              class="mr-2 underline"
            >
              Open
            </RouterLink>
            <button
              v-if="allowed('ops.impersonation.start') && p.livemode"
              type="button"
              class="text-red-700 underline"
              @click="target = p"
            >
              View as merchant
            </button>
          </td>
        </tr>
      </tbody>
    </table>
    <p
      v-if="results.data.value && results.data.value.data.length === 0"
      class="text-slate-600"
    >
      No payment matches.
    </p>

    <ImpersonationDialog
      v-if="target"
      :open="!!target"
      :merchant-id="target.merchant_id"
      :merchant-name="target.merchant"
      @update:open="(o: boolean) => { if (!o) target = null }"
    />
  </div>
</template>
