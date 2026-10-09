<script setup lang="ts">
import { computed, ref } from "vue";
import { useQuery, useQueryClient } from "@tanstack/vue-query";
import { api } from "../api";
import { useMe } from "../useMe";
import { ApiFailure } from "../../shared/http";
import { formatMoney } from "../../shared/money";
import BaseModal from "../../shared/components/BaseModal.vue";
import ErrorBanner from "../../shared/components/ErrorBanner.vue";
import StatusBadge from "../../shared/components/StatusBadge.vue";
import type { Reconciliation, SettlementBreak } from "../types";

const { allowed } = useMe();
const queryClient = useQueryClient();
const { data } = useQuery({ queryKey: ["ops-reconciliation"], queryFn: () => api.get<Reconciliation>("/reconciliation_breaks") });

const reviewing = ref<SettlementBreak | null>(null);
const note = ref("");
const error = ref<string | null>(null);
const busy = ref(false);

const canReview = computed(() => allowed("ops.reconciliation.review"));

async function review() {
  if (!reviewing.value) return;
  busy.value = true;
  error.value = null;
  try {
    await api.post(`/reconciliation_breaks/${reviewing.value.id}/review`, { reason: note.value });
    reviewing.value = null;
    note.value = "";
    await queryClient.invalidateQueries({ queryKey: ["ops-reconciliation"] });
  } catch (e) {
    error.value = e instanceof ApiFailure ? e.message : "Something went wrong. Try again.";
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <div class="space-y-8">
    <h1 class="text-2xl font-semibold">
      Reconciliation
    </h1>

    <section aria-labelledby="settlement">
      <h2
        id="settlement"
        class="mb-2 text-lg font-semibold"
      >
        Settlement breaks
      </h2>
      <p
        v-if="(data?.settlement_lines.length ?? 0) === 0"
        class="text-slate-600"
      >
        No settlement break.
      </p>
      <table
        v-else
        class="w-full rounded bg-white text-sm shadow-sm"
      >
        <thead class="text-left text-slate-500">
          <tr>
            <th class="p-2">
              PSP
            </th><th class="p-2">
              Kind
            </th><th class="p-2">
              Status
            </th><th class="p-2">
              Net
            </th><th class="p-2">
              Problem
            </th><th class="p-2" />
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="l in data?.settlement_lines ?? []"
            :key="l.id"
            class="border-t border-slate-100"
          >
            <td class="p-2">
              {{ l.psp_name }}
            </td>
            <td class="p-2">
              {{ l.kind }}
            </td>
            <td class="p-2">
              <StatusBadge :status="l.status" />
            </td>
            <td class="p-2">
              {{ formatMoney(l.net_minor, l.currency) }}
            </td>
            <td class="p-2 text-xs text-slate-500">
              {{ l.problem ?? "" }}
            </td>
            <td class="p-2 text-right">
              <RouterLink
                v-if="l.payment_id"
                :to="`/payments/${l.payment_id}`"
                class="mr-2 underline"
              >
                payment
              </RouterLink>
              <button
                v-if="canReview"
                type="button"
                class="underline"
                @click="reviewing = l; note = ''"
              >
                Review
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </section>

    <section aria-labelledby="ledger">
      <h2
        id="ledger"
        class="mb-2 text-lg font-semibold"
      >
        Ledger anomalies
      </h2>
      <p class="text-sm text-slate-500">
        Fixing a ledger anomaly is a proposal: open the related payment and propose a correction.
      </p>
      <div class="mt-2 grid gap-4 sm:grid-cols-2">
        <div class="rounded bg-white p-3 text-sm shadow-sm">
          <h3 class="font-medium">
            Unbalanced transfers
          </h3>
          <p
            v-if="(data?.ledger.unbalanced_transfer_ids.length ?? 0) === 0"
            class="text-slate-600"
          >
            None.
          </p>
          <ul
            v-else
            class="mt-1 space-y-1 font-mono text-xs"
          >
            <li
              v-for="t in data?.ledger.unbalanced_transfer_ids ?? []"
              :key="t"
              class="flex items-center gap-2"
            >
              <span>{{ t }}</span>
              <RouterLink
                to="/proposals"
                class="font-sans underline"
              >
                propose correction
              </RouterLink>
            </li>
          </ul>
        </div>
        <div class="rounded bg-white p-3 text-sm shadow-sm">
          <h3 class="font-medium">
            Reservation drift refunds
          </h3>
          <p
            v-if="(data?.ledger.reservation_drift_refund_ids.length ?? 0) === 0"
            class="text-slate-600"
          >
            None.
          </p>
          <ul
            v-else
            class="mt-1 space-y-1 font-mono text-xs"
          >
            <li
              v-for="r in data?.ledger.reservation_drift_refund_ids ?? []"
              :key="r"
              class="flex items-center gap-2"
            >
              <span>{{ r }}</span>
              <RouterLink
                to="/proposals"
                class="font-sans underline"
              >
                propose correction
              </RouterLink>
            </li>
          </ul>
        </div>
      </div>
    </section>

    <BaseModal
      :open="!!reviewing"
      title="Review this break"
      description="A note is required; it is written to the audit stream."
      @update:open="(o: boolean) => { if (!o) reviewing = null }"
    >
      <form
        class="space-y-3"
        @submit.prevent="review"
      >
        <label class="block text-sm font-medium text-slate-700">
          Note
          <textarea
            v-model="note"
            rows="3"
            class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          />
        </label>
        <ErrorBanner :message="error" />
        <button
          type="submit"
          :disabled="busy || note.trim() === ''"
          class="w-full rounded bg-slate-900 px-3 py-2 text-white disabled:opacity-50"
        >
          Mark reviewed
        </button>
      </form>
    </BaseModal>
  </div>
</template>
