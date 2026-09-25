<script setup lang="ts">
import { computed } from "vue";
import { useInfiniteQuery } from "@tanstack/vue-query";
import { api } from "../api";
import StatusBadge from "../../shared/components/StatusBadge.vue";
import type { List } from "../types";

type Row = { id: string; at: string; actor: string | null; action: string; result: string; ip: string | null };

const list = useInfiniteQuery({
  queryKey: ["security-history"],
  initialPageParam: null as string | null,
  queryFn: ({ pageParam }) => api.get<List<Row>>(`/security_history${pageParam ? `?cursor=${pageParam}` : ""}`),
  getNextPageParam: (last) => (last.has_more ? last.next_cursor : null),
});
const rows = computed(() => list.data.value?.pages.flatMap((p) => p.data) ?? []);
</script>

<template>
  <div class="space-y-4">
    <div class="flex items-center">
      <h1 class="text-2xl font-semibold">
        Security history
      </h1>
      <a
        href="/dashboard/api/security_history/export.csv"
        class="ml-auto text-sm underline"
      >Export CSV</a>
    </div>
    <table class="w-full rounded bg-white text-sm shadow-sm">
      <thead class="text-left text-slate-500">
        <tr>
          <th class="p-2">
            When
          </th><th class="p-2">
            Who
          </th><th class="p-2">
            What
          </th><th class="p-2">
            Result
          </th><th class="p-2">
            IP
          </th>
        </tr>
      </thead>
      <tbody>
        <tr
          v-for="r in rows"
          :key="r.id"
          class="border-t border-slate-100"
        >
          <td class="p-2">
            {{ new Date(r.at).toLocaleString() }}
          </td>
          <td class="p-2">
            {{ r.actor ?? "—" }}
          </td>
          <td class="p-2 font-mono text-xs">
            {{ r.action }}
          </td>
          <td class="p-2">
            <StatusBadge :status="r.result" />
          </td>
          <td class="p-2">
            {{ r.ip ?? "—" }}
          </td>
        </tr>
      </tbody>
    </table>
    <button
      v-if="list.hasNextPage.value"
      type="button"
      class="rounded border border-slate-300 bg-white px-3 py-1 text-sm"
      @click="list.fetchNextPage()"
    >
      Load more
    </button>
  </div>
</template>
