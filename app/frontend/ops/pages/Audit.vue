<script setup lang="ts">
import { computed, reactive, ref, watch } from "vue";
import { useQuery } from "@tanstack/vue-query";
import { api } from "../api";
import StatusBadge from "../../shared/components/StatusBadge.vue";
import type { AuditRow, List } from "../types";

const filters = reactive({ actor_type: "", action_prefix: "", merchant_id: "", on_behalf_of_merchant_id: "", from: "", to: "" });
const query = computed(() => {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(filters)) if (v) p.set(k, v);
  return p.toString();
});

const base = useQuery({
  queryKey: computed(() => ["ops-audit", query.value]),
  queryFn: () => api.get<List<AuditRow>>(`/audit_events${query.value ? `?${query.value}` : ""}`),
});

const extra = ref<AuditRow[]>([]);
const cursor = ref<string | null>(null);
watch(base.data, () => {
  extra.value = [];
  cursor.value = base.data.value?.next_cursor ?? null;
});

const rows = computed(() => [...(base.data.value?.data ?? []), ...extra.value]);

async function more() {
  if (!cursor.value) return;
  const page = await api.get<List<AuditRow>>(`/audit_events?${query.value}&cursor=${cursor.value}`);
  extra.value.push(...page.data);
  cursor.value = page.next_cursor ?? null;
}
</script>

<template>
  <div class="space-y-4">
    <h1 class="text-2xl font-semibold">
      Audit stream
    </h1>
    <form
      class="grid gap-2 rounded bg-white p-3 text-sm shadow-sm sm:grid-cols-3 lg:grid-cols-6"
      @submit.prevent
    >
      <select
        v-model="filters.actor_type"
        class="rounded border border-slate-300 px-2 py-1"
      >
        <option value="">
          Any actor
        </option>
        <option value="operator">
          operator
        </option>
        <option value="merchant">
          merchant
        </option>
      </select>
      <input
        v-model="filters.action_prefix"
        placeholder="action prefix (e.g. proposal.)"
        class="rounded border border-slate-300 px-2 py-1"
      >
      <input
        v-model="filters.merchant_id"
        placeholder="merchant id"
        class="rounded border border-slate-300 px-2 py-1"
      >
      <input
        v-model="filters.on_behalf_of_merchant_id"
        placeholder="impersonated merchant id"
        class="rounded border border-slate-300 px-2 py-1"
      >
      <input
        v-model="filters.from"
        type="datetime-local"
        class="rounded border border-slate-300 px-2 py-1"
      >
      <input
        v-model="filters.to"
        type="datetime-local"
        class="rounded border border-slate-300 px-2 py-1"
      >
    </form>

    <table class="w-full rounded bg-white text-sm shadow-sm">
      <thead class="text-left text-slate-500">
        <tr>
          <th class="p-2">
            When
          </th><th class="p-2">
            Actor
          </th><th class="p-2">
            Action
          </th><th class="p-2">
            Result
          </th><th class="p-2">
            Merchant
          </th><th class="p-2">
            On behalf of
          </th><th class="p-2">
            Target
          </th>
        </tr>
      </thead>
      <tbody>
        <tr
          v-for="e in rows"
          :key="e.id"
          class="border-t border-slate-100"
        >
          <td class="p-2 whitespace-nowrap">
            {{ new Date(e.at).toLocaleString() }}
          </td>
          <td class="p-2">
            {{ e.actor_type }}: {{ e.actor }}
          </td>
          <td class="p-2 font-mono text-xs">
            {{ e.action }}
          </td>
          <td class="p-2">
            <StatusBadge :status="e.result" />
          </td>
          <td class="p-2 font-mono text-xs">
            {{ e.merchant_id ?? "—" }}
          </td>
          <td class="p-2 font-mono text-xs">
            {{ e.on_behalf_of_merchant_id ?? "—" }}
          </td>
          <td class="p-2 font-mono text-xs">
            {{ e.target_type ? `${e.target_type}:${e.target_id}` : "—" }}
          </td>
        </tr>
      </tbody>
    </table>
    <p
      v-if="base.data.value && rows.length === 0"
      class="text-slate-600"
    >
      No audit event.
    </p>
    <button
      v-if="cursor"
      type="button"
      class="rounded border border-slate-300 bg-white px-3 py-1.5 text-sm"
      @click="more"
    >
      Load more
    </button>
  </div>
</template>
