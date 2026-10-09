<script setup lang="ts">
import { api } from "../api";
import { useLiveQuery } from "../../shared/useLiveQuery";
import StatusBadge from "../../shared/components/StatusBadge.vue";
import type { Circuit, List } from "../types";

const { data } = useLiveQuery<List<Circuit>>(
  ["ops-circuits"],
  (poll) => api.get<List<Circuit>>("/circuits", { poll }),
  () => 10_000,
);
</script>

<template>
  <div class="space-y-4">
    <h1 class="text-2xl font-semibold">
      PSP circuits
    </h1>
    <p class="text-sm text-slate-500">
      Read-only. The breaker opens and closes by itself from live traffic.
    </p>
    <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      <article
        v-for="c in data?.data ?? []"
        :key="c.psp"
        class="rounded bg-white p-4 shadow-sm"
      >
        <div class="flex items-center gap-2">
          <h2 class="text-lg font-semibold">
            {{ c.psp }}
          </h2>
          <StatusBadge :status="c.state" />
        </div>
        <dl class="mt-2 space-y-1 text-sm">
          <div class="flex justify-between">
            <dt class="text-slate-500">
              Window calls
            </dt>
            <dd>{{ c.window_calls }}</dd>
          </div>
          <div class="flex justify-between">
            <dt class="text-slate-500">
              Window failures
            </dt>
            <dd>{{ c.window_failures }}</dd>
          </div>
          <div class="flex justify-between">
            <dt class="text-slate-500">
              Open until
            </dt>
            <dd>{{ c.open_until ? new Date(c.open_until).toLocaleTimeString() : "—" }}</dd>
          </div>
        </dl>
      </article>
    </div>
  </div>
</template>
