<script setup lang="ts">
import { computed } from "vue";
import { useInfiniteQuery } from "@tanstack/vue-query";
import { useRoute, useRouter } from "vue-router";
import { api } from "../api";
import { useMe } from "../useMe";
import { formatMoney } from "../../shared/money";
import StatusBadge from "../../shared/components/StatusBadge.vue";
import type { List, Payment } from "../types";

const route = useRoute();
const router = useRouter();
const { allowed } = useMe();

const STATES = ["pending", "requires_action", "authorized", "unknown", "captured", "part_refunded", "refunded", "canceled", "failed"];

// Filters live in the URL, so a filtered list can be shared and survives reload.
const filters = computed(() => {
  const q: Record<string, string> = {};
  for (const k of ["state", "currency", "created_after", "created_before"]) {
    const v = route.query[k];
    if (typeof v === "string" && v !== "") q[k] = v;
  }
  return q;
});

function setFilter(k: string, v: string) {
  router.replace({ query: { ...filters.value, [k]: v || undefined } });
}

const list = useInfiniteQuery({
  queryKey: computed(() => ["payments", filters.value]),
  initialPageParam: null as string | null,
  queryFn: ({ pageParam }) => {
    const params = new URLSearchParams({ ...filters.value, ...(pageParam ? { cursor: pageParam } : {}) });
    return api.get<List<Payment>>(`/payments?${params}`);
  },
  getNextPageParam: (last) => (last.has_more ? last.next_cursor : null),
});
const rows = computed(() => list.data.value?.pages.flatMap((p) => p.data) ?? []);
const exportHref = computed(() => `/dashboard/api/payments/export.csv?${new URLSearchParams(filters.value)}`);
</script>

<template>
  <div class="space-y-4">
    <div class="flex items-end gap-3">
      <h1 class="text-2xl font-semibold">
        Payments
      </h1>
      <a
        v-if="allowed('payments.export')"
        :href="exportHref"
        class="ml-auto text-sm underline"
      >Export CSV</a>
    </div>
    <div class="flex flex-wrap gap-3 text-sm">
      <label>State
        <select
          :value="filters.state ?? ''"
          class="ml-1 rounded border border-slate-300 px-2 py-1"
          @change="setFilter('state', ($event.target as HTMLSelectElement).value)"
        >
          <option value="">Any</option>
          <option
            v-for="s in STATES"
            :key="s"
            :value="s"
          >{{ s.replaceAll("_", " ") }}</option>
        </select>
      </label>
      <label>Currency
        <input
          :value="filters.currency ?? ''"
          maxlength="3"
          class="ml-1 w-16 rounded border border-slate-300 px-2 py-1 uppercase"
          @change="setFilter('currency', ($event.target as HTMLInputElement).value.toUpperCase())"
        >
      </label>
      <label>From
        <input
          type="date"
          :value="filters.created_after?.slice(0, 10) ?? ''"
          class="ml-1 rounded border border-slate-300 px-2 py-1"
          @change="setFilter('created_after', ($event.target as HTMLInputElement).value ? `${($event.target as HTMLInputElement).value}T00:00:00Z` : '')"
        >
      </label>
      <label>To
        <input
          type="date"
          :value="filters.created_before?.slice(0, 10) ?? ''"
          class="ml-1 rounded border border-slate-300 px-2 py-1"
          @change="setFilter('created_before', ($event.target as HTMLInputElement).value ? `${($event.target as HTMLInputElement).value}T23:59:59Z` : '')"
        >
      </label>
    </div>
    <table class="w-full rounded bg-white text-sm shadow-sm">
      <thead class="text-left text-slate-500">
        <tr>
          <th class="p-2">
            Created
          </th>
          <th class="p-2">
            Amount
          </th>
          <th class="p-2">
            State
          </th>
          <th class="p-2">
            Reference
          </th>
        </tr>
      </thead>
      <tbody>
        <tr
          v-for="p in rows"
          :key="p.id"
          class="border-t border-slate-100"
        >
          <td class="p-2">
            {{ new Date(p.created_at).toLocaleString() }}
          </td>
          <td class="p-2">
            <RouterLink
              :to="`/payments/${p.id}`"
              class="underline"
            >
              {{ formatMoney(p.amount_minor, p.currency) }} · {{ p.state.replaceAll("_", " ") }}
            </RouterLink>
          </td>
          <td class="p-2">
            <StatusBadge :status="p.state" />
          </td>
          <td class="p-2 font-mono text-xs">
            {{ p.psp_reference }}
          </td>
        </tr>
      </tbody>
    </table>
    <p
      v-if="rows.length === 0 && !list.isLoading.value"
      class="text-slate-600"
    >
      No payments match these filters.
    </p>
    <button
      v-if="list.hasNextPage.value"
      type="button"
      class="rounded border border-slate-300 bg-white px-3 py-1 text-sm"
      :disabled="list.isFetchingNextPage.value"
      @click="list.fetchNextPage()"
    >
      Load more
    </button>
  </div>
</template>
