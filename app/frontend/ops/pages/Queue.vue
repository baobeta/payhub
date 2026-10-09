<script setup lang="ts">
import { api } from "../api";
import { useLiveQuery } from "../../shared/useLiveQuery";
import { formatMoney } from "../../shared/money";
import type { Queue } from "../types";

const { data, isError } = useLiveQuery<Queue>(
  ["ops-queue"],
  (poll) => api.get<Queue>("/queue", { poll }),
  () => 30_000,
);

function relative(iso: string): string {
  const seconds = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.round(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.round(seconds / 3600)}h`;
  return `${Math.round(seconds / 86400)}d`;
}
</script>

<template>
  <div class="space-y-8">
    <h1 class="text-2xl font-semibold">
      Needs attention
    </h1>
    <p
      v-if="isError"
      role="alert"
    >
      Could not load the queue.
    </p>
    <template v-if="data">
      <section aria-labelledby="unknown">
        <h2
          id="unknown"
          class="mb-2 text-lg font-semibold"
        >
          Unknown payments
          <span class="text-sm font-normal text-slate-500">({{ data.unknown_payments.length }})</span>
        </h2>
        <p
          v-if="data.unknown_payments.length === 0"
          class="text-slate-600"
        >
          No payment is stuck.
        </p>
        <table
          v-else
          class="w-full rounded bg-white text-sm shadow-sm"
        >
          <thead class="text-left text-slate-500">
            <tr>
              <th class="p-2">
                Merchant
              </th><th class="p-2">
                Amount
              </th><th class="p-2">
                Stuck for
              </th><th class="p-2">
                Checks
              </th><th class="p-2">
                Reference
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-for="p in data.unknown_payments"
              :key="p.id"
              class="border-t border-slate-100"
            >
              <td class="p-2">
                {{ p.merchant }}
              </td>
              <td class="p-2">
                <RouterLink
                  :to="`/payments/${p.id}`"
                  class="underline"
                >
                  {{ formatMoney(p.amount_minor, p.currency) }}
                </RouterLink>
              </td>
              <td class="p-2">
                {{ relative(p.stuck_since) }}
              </td>
              <td class="p-2">
                {{ p.check_attempts }}
              </td>
              <td class="p-2 font-mono text-xs">
                {{ p.psp_reference }}
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      <section aria-labelledby="dead">
        <h2
          id="dead"
          class="mb-2 text-lg font-semibold"
        >
          Dead webhooks
          <span class="text-sm font-normal text-slate-500">({{ data.dead_events.length }})</span>
        </h2>
        <p
          v-if="data.dead_events.length === 0"
          class="text-slate-600"
        >
          No dead webhook.
        </p>
        <ul
          v-else
          class="divide-y divide-slate-100 rounded bg-white text-sm shadow-sm"
        >
          <li
            v-for="e in data.dead_events"
            :key="e.id"
            class="flex items-center gap-3 p-3"
          >
            <span class="font-mono">{{ e.type }}</span>
            <span class="text-slate-500">{{ e.merchant }}</span>
            <span
              v-if="e.last_error"
              class="text-xs text-red-700"
            >{{ e.last_error }}</span>
            <span class="ml-auto text-slate-500">dead {{ relative(e.dead_since) }}</span>
            <RouterLink
              v-if="e.payment_id"
              :to="`/payments/${e.payment_id}`"
              class="underline"
            >
              payment
            </RouterLink>
          </li>
        </ul>
      </section>

      <section
        aria-labelledby="counts"
        class="flex gap-4"
      >
        <h2
          id="counts"
          class="sr-only"
        >
          Other queues
        </h2>
        <RouterLink
          to="/reconciliation"
          class="rounded border border-slate-300 bg-white px-4 py-3"
        >
          <span class="text-2xl font-semibold">{{ data.reconciliation_breaks }}</span>
          <span class="ml-2">unreviewed settlement breaks</span>
        </RouterLink>
        <RouterLink
          to="/proposals"
          class="rounded border border-slate-300 bg-white px-4 py-3"
        >
          <span class="text-2xl font-semibold">{{ data.open_proposals }}</span>
          <span class="ml-2">open proposals</span>
        </RouterLink>
      </section>
    </template>
  </div>
</template>
