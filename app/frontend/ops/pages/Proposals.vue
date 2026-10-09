<script setup lang="ts">
import { computed, ref } from "vue";
import { useQuery } from "@tanstack/vue-query";
import { api } from "../api";
import StatusBadge from "../../shared/components/StatusBadge.vue";
import type { List, Proposal } from "../types";

const state = ref("");
const list = useQuery({
  queryKey: computed(() => ["ops-proposals", state.value]),
  queryFn: () => api.get<List<Proposal>>(`/proposals${state.value ? `?state=${state.value}` : ""}`),
});
</script>

<template>
  <div class="space-y-4">
    <div class="flex items-center gap-3">
      <h1 class="text-2xl font-semibold">
        Proposals
      </h1>
      <label class="ml-auto text-sm">State
        <select
          v-model="state"
          class="ml-1 rounded border border-slate-300 px-2 py-1"
        >
          <option value="">Any</option>
          <option value="pending">pending</option>
          <option value="applied">applied</option>
          <option value="failed">failed</option>
          <option value="rejected">rejected</option>
          <option value="withdrawn">withdrawn</option>
        </select>
      </label>
    </div>
    <table class="w-full rounded bg-white text-sm shadow-sm">
      <thead class="text-left text-slate-500">
        <tr>
          <th class="p-2">
            State
          </th><th class="p-2">
            Kind
          </th><th class="p-2">
            Merchant
          </th><th class="p-2">
            Proposer
          </th><th class="p-2">
            Case
          </th><th class="p-2">
            Created
          </th>
        </tr>
      </thead>
      <tbody>
        <tr
          v-for="p in list.data.value?.data ?? []"
          :key="p.id"
          class="border-t border-slate-100"
        >
          <td class="p-2">
            <StatusBadge :status="p.state" />
          </td>
          <td class="p-2">
            {{ p.kind.replaceAll("_", " ") }}
          </td>
          <td class="p-2">
            {{ p.merchant }}
          </td>
          <td class="p-2">
            {{ p.proposed_by }}
          </td>
          <td class="p-2">
            <RouterLink
              :to="`/proposals/${p.id}`"
              class="underline"
            >
              {{ p.case_reference }}
            </RouterLink>
          </td>
          <td class="p-2">
            {{ new Date(p.created_at).toLocaleString() }}
          </td>
        </tr>
      </tbody>
    </table>
    <p
      v-if="list.data.value && list.data.value.data.length === 0"
      class="text-slate-600"
    >
      No proposal.
    </p>
  </div>
</template>
