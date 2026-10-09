<script setup lang="ts">
import { computed, ref } from "vue";
import { useQuery, useQueryClient } from "@tanstack/vue-query";
import { useRoute } from "vue-router";
import { api } from "../api";
import { ApiFailure } from "../../shared/http";
import ErrorBanner from "../../shared/components/ErrorBanner.vue";
import StatusBadge from "../../shared/components/StatusBadge.vue";
import type { List, PaymentDetail, Proposal } from "../types";

const route = useRoute();
const queryClient = useQueryClient();
const id = computed(() => String(route.params.id));

const list = useQuery({
  queryKey: computed(() => ["ops-proposals", ""]),
  queryFn: () => api.get<List<Proposal>>("/proposals"),
});
const proposal = computed(() => list.data.value?.data.find((p) => p.id === id.value) ?? null);

const payment = useQuery({
  queryKey: computed(() => ["ops-payment", proposal.value?.payment_id ?? ""]),
  enabled: () => !!proposal.value,
  queryFn: () => api.get<PaymentDetail>(`/payments/${proposal.value!.payment_id}`),
});

const note = ref("");
const error = ref<string | null>(null);
const busy = ref(false);

async function decide(approve: boolean) {
  busy.value = true;
  error.value = null;
  try {
    await api.post(`/proposals/${id.value}/${approve ? "approve" : "reject"}`, { note: note.value });
    note.value = "";
    await queryClient.invalidateQueries({ queryKey: ["ops-proposals"] });
  } catch (e) {
    error.value = e instanceof ApiFailure ? e.message : "Something went wrong. Try again.";
  } finally {
    busy.value = false;
  }
}

async function withdraw() {
  busy.value = true;
  error.value = null;
  try {
    await api.post(`/proposals/${id.value}/withdraw`);
    await queryClient.invalidateQueries({ queryKey: ["ops-proposals"] });
  } catch (e) {
    error.value = e instanceof ApiFailure ? e.message : "Something went wrong. Try again.";
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <p
    v-if="list.isError.value"
    role="alert"
  >
    Could not load proposals.
  </p>
  <p
    v-else-if="list.data.value && !proposal"
    role="alert"
  >
    This proposal does not exist.
  </p>
  <div
    v-else-if="proposal"
    class="max-w-3xl space-y-6"
  >
    <div class="flex items-center gap-3">
      <h1 class="text-2xl font-semibold">
        Proposal {{ proposal.case_reference }}
      </h1>
      <StatusBadge :status="proposal.state" />
      <span class="text-slate-500">{{ proposal.kind.replaceAll("_", " ") }}</span>
    </div>

    <dl class="grid grid-cols-2 gap-x-6 gap-y-2 text-sm">
      <dt class="text-slate-500">
        Merchant
      </dt>
      <dd>{{ proposal.merchant }}</dd>
      <dt class="text-slate-500">
        Proposed by
      </dt>
      <dd>{{ proposal.proposed_by }}</dd>
      <dt class="text-slate-500">
        Reason code
      </dt>
      <dd>{{ proposal.reason_code }}</dd>
      <dt class="text-slate-500">
        Case reference
      </dt>
      <dd>{{ proposal.case_reference }}</dd>
      <dt class="text-slate-500">
        Payment state
      </dt>
      <dd>
        <StatusBadge
          v-if="payment.data.value"
          :status="payment.data.value.state"
        />
        <RouterLink
          :to="`/payments/${proposal.payment_id}`"
          class="ml-2 underline"
        >
          open payment
        </RouterLink>
      </dd>
      <dt class="text-slate-500">
        Last PSP call
      </dt>
      <dd>
        <template v-if="payment.data.value?.psp_calls.at(-1)">
          {{ payment.data.value.psp_calls.at(-1)!.operation }} → {{ payment.data.value.psp_calls.at(-1)!.outcome }}
        </template>
        <span v-else>none</span>
      </dd>
    </dl>

    <section class="rounded bg-white p-3 text-sm shadow-sm">
      <h2 class="mb-1 font-medium">
        What the proposer says
      </h2>
      <p class="whitespace-pre-wrap">
        {{ proposal.reason_text }}
      </p>
    </section>

    <section class="rounded bg-slate-50 p-3 text-sm">
      <h2 class="mb-1 font-medium">
        Payload
      </h2>
      <pre class="overflow-x-auto">{{ JSON.stringify(proposal.payload, null, 2) }}</pre>
    </section>

    <section
      v-if="proposal.state === 'applied'"
      data-testid="proposal-outcome"
      class="rounded border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-900"
    >
      Applied{{ proposal.applied_transfer_id ? ` (transfer ${proposal.applied_transfer_id})` : "" }}.
    </section>
    <section
      v-else-if="proposal.state === 'failed'"
      data-testid="proposal-outcome"
      class="rounded border border-red-200 bg-red-50 p-3 text-sm text-red-900"
    >
      Failed: {{ proposal.error }}
    </section>
    <section
      v-else-if="proposal.state === 'rejected'"
      data-testid="proposal-outcome"
      class="rounded border border-slate-200 bg-slate-50 p-3 text-sm"
    >
      Rejected by {{ proposal.decided_by }}<span v-if="proposal.decision_note"> — {{ proposal.decision_note }}</span>
    </section>

    <ErrorBanner :message="error" />

    <div
      v-if="proposal.state === 'pending'"
      class="space-y-3"
    >
      <label class="block text-sm font-medium text-slate-700">
        Note (required to reject)
        <textarea
          v-model="note"
          rows="2"
          class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
        />
      </label>
      <div class="flex gap-2">
        <button
          v-if="proposal.can.approve"
          type="button"
          class="rounded bg-emerald-700 px-4 py-2 text-white disabled:opacity-50"
          :disabled="busy"
          @click="decide(true)"
        >
          Approve
        </button>
        <button
          v-if="proposal.can.reject"
          type="button"
          class="rounded bg-red-700 px-4 py-2 text-white disabled:opacity-50"
          :disabled="busy || note.trim() === ''"
          @click="decide(false)"
        >
          Reject
        </button>
        <button
          v-if="proposal.can.withdraw"
          type="button"
          class="rounded border border-slate-300 bg-white px-4 py-2 disabled:opacity-50"
          :disabled="busy"
          @click="withdraw"
        >
          Withdraw
        </button>
      </div>
    </div>
  </div>
</template>
