<script setup lang="ts">
import { computed, ref } from "vue";
import { useQueryClient } from "@tanstack/vue-query";
import { useRoute } from "vue-router";
import { api } from "../api";
import { useMe } from "../useMe";
import { ApiFailure } from "../../shared/http";
import { useLiveQuery } from "../../shared/useLiveQuery";
import { pollIntervalFor } from "../../shared/pollInterval";
import { formatMoney } from "../../shared/money";
import StatusBadge from "../../shared/components/StatusBadge.vue";
import ErrorBanner from "../../shared/components/ErrorBanner.vue";
import PaymentTimeline from "../../shared/components/PaymentTimeline.vue";
import ProposeDialog from "../components/ProposeDialog.vue";
import ImpersonationDialog from "../components/ImpersonationDialog.vue";
import type { PaymentDetail } from "../types";

const route = useRoute();
const queryClient = useQueryClient();
const { allowed } = useMe();
const id = computed(() => String(route.params.id));
const key = computed(() => ["ops-payment", id.value]);

const { data: payment, isError } = useLiveQuery<PaymentDetail>(
  key,
  (poll) => api.get(`/payments/${id.value}`, { poll }),
  (p) => pollIntervalFor(p.state),
);

const pollError = ref<string | null>(null);
const polling = ref(false);
const proposeOpen = ref(false);
const impersonateOpen = ref(false);

function refresh() {
  queryClient.invalidateQueries({ queryKey: key.value });
}

async function poll() {
  polling.value = true;
  pollError.value = null;
  try {
    await api.post(`/payments/${id.value}/poll`);
  } catch (e) {
    pollError.value = e instanceof ApiFailure ? e.message : "Could not poll the PSP. Try again.";
  } finally {
    polling.value = false;
    refresh();
  }
}

function callOutcome(outcome: string, durationMs: number | null): string {
  if (outcome === "timeout") return `no response (timed out after ${durationMs ?? "?"} ms)`;
  return outcome;
}

const latestCall = computed(() => payment.value?.psp_calls.at(-1) ?? null);
const latestWebhook = computed(() => payment.value?.inbound_events.at(-1) ?? null);

function onProposed() {
  refresh();
}
</script>

<template>
  <p
    v-if="isError"
    role="alert"
  >
    This payment does not exist.
  </p>
  <div
    v-else-if="payment"
    class="space-y-6"
  >
    <div class="flex flex-wrap items-center gap-3">
      <h1 class="text-2xl font-semibold">
        {{ formatMoney(payment.amount_minor, payment.currency) }}
      </h1>
      <StatusBadge :status="payment.state" />
      <span class="text-slate-600">{{ payment.merchant.name }}</span>
      <span
        class="rounded px-2 py-0.5 text-xs font-medium ring-1 ring-inset"
        :class="payment.merchant.livemode ? 'bg-slate-900 text-white ring-slate-900' : 'bg-amber-100 text-amber-900 ring-amber-300'"
      >{{ payment.merchant.livemode ? "Live" : "Test" }}</span>
      <div class="ml-auto flex gap-2">
        <button
          v-if="allowed('ops.payments.poll')"
          type="button"
          class="rounded border border-slate-300 bg-white px-3 py-1.5 text-sm"
          :disabled="polling"
          @click="poll"
        >
          Poll PSP now
        </button>
        <button
          v-if="allowed('ops.impersonation.start') && payment.merchant.livemode"
          type="button"
          class="rounded border border-red-300 px-3 py-1.5 text-sm text-red-700"
          @click="impersonateOpen = true"
        >
          View as merchant
        </button>
        <button
          v-if="allowed('ops.proposals.create') && payment.state === 'unknown'"
          type="button"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm text-white"
          @click="proposeOpen = true"
        >
          Propose resolution
        </button>
      </div>
    </div>
    <ErrorBanner :message="pollError" />
    <dl class="grid grid-cols-2 gap-x-6 gap-y-1 text-sm md:grid-cols-4">
      <dt class="text-slate-500">
        PSP
      </dt>
      <dd>{{ payment.psp_name }}</dd>
      <dt class="text-slate-500">
        Reference
      </dt>
      <dd class="font-mono text-xs">
        {{ payment.psp_reference }}
      </dd>
      <dt class="text-slate-500">
        Captured
      </dt>
      <dd>{{ formatMoney(payment.captured_minor, payment.currency) }}</dd>
      <dt class="text-slate-500">
        Created
      </dt>
      <dd>{{ new Date(payment.created_at).toLocaleString() }}</dd>
    </dl>

    <section aria-labelledby="timeline">
      <h2
        id="timeline"
        class="mb-3 text-sm font-medium uppercase text-slate-500"
      >
        Timeline
      </h2>
      <PaymentTimeline
        :entries="payment.timeline"
        :currency="payment.currency"
      />
    </section>

    <section aria-labelledby="psp-calls">
      <h2
        id="psp-calls"
        class="mb-3 text-sm font-medium uppercase text-slate-500"
      >
        PSP calls
      </h2>
      <p
        v-if="payment.psp_calls.length === 0"
        class="text-slate-600"
      >
        No call recorded.
      </p>
      <table
        v-else
        class="w-full rounded bg-white text-sm shadow-sm"
      >
        <thead class="text-left text-slate-500">
          <tr>
            <th class="p-2">
              When
            </th><th class="p-2">
              Operation
            </th><th class="p-2">
              Outcome
            </th><th class="p-2">
              HTTP
            </th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="(c, i) in payment.psp_calls"
            :key="i"
            class="border-t border-slate-100"
          >
            <td class="p-2">
              {{ new Date(c.sent_at).toLocaleString() }}
            </td>
            <td class="p-2 font-mono text-xs">
              {{ c.operation }}
            </td>
            <td class="p-2">
              {{ callOutcome(c.outcome, c.duration_ms) }}
            </td>
            <td class="p-2">
              {{ c.http_status ?? "—" }}
            </td>
          </tr>
        </tbody>
      </table>
    </section>

    <section aria-labelledby="webhooks">
      <h2
        id="webhooks"
        class="mb-3 text-sm font-medium uppercase text-slate-500"
      >
        Inbound webhooks
      </h2>
      <p
        v-if="payment.inbound_events.length === 0"
        class="text-slate-600"
      >
        No webhook recorded.
      </p>
      <table
        v-else
        class="w-full rounded bg-white text-sm shadow-sm"
      >
        <thead class="text-left text-slate-500">
          <tr>
            <th class="p-2">
              When
            </th><th class="p-2">
              Type
            </th><th class="p-2">
              Signature
            </th><th class="p-2">
              Error
            </th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="(e, i) in payment.inbound_events"
            :key="i"
            class="border-t border-slate-100"
          >
            <td class="p-2">
              {{ new Date(e.received_at).toLocaleString() }}
            </td>
            <td class="p-2 font-mono text-xs">
              {{ e.event_type }}
            </td>
            <td class="p-2">
              <StatusBadge
                v-if="!e.signature_valid"
                status="denied"
              />
              <span v-else>valid</span>
            </td>
            <td class="p-2 text-xs text-red-700">
              {{ e.error ?? "" }}
            </td>
          </tr>
        </tbody>
      </table>
    </section>

    <section aria-labelledby="proposals">
      <h2
        id="proposals"
        class="mb-3 text-sm font-medium uppercase text-slate-500"
      >
        Proposals
      </h2>
      <p
        v-if="payment.proposals.length === 0"
        class="text-slate-600"
      >
        No proposal raised.
      </p>
      <ul
        v-else
        class="divide-y divide-slate-100 rounded bg-white text-sm shadow-sm"
      >
        <li
          v-for="pr in payment.proposals"
          :key="pr.id"
          class="flex items-center gap-3 p-3"
        >
          <StatusBadge :status="pr.state" />
          <span>{{ pr.kind.replaceAll("_", " ") }}</span>
          <span class="text-slate-500">{{ pr.reason_code }}</span>
          <RouterLink
            :to="`/proposals/${pr.id}`"
            class="ml-auto underline"
          >
            {{ pr.case_reference }}
          </RouterLink>
        </li>
      </ul>
    </section>

    <ProposeDialog
      v-model:open="proposeOpen"
      :payment-id="payment.id"
      :current-state="payment.state"
      :latest-call="latestCall"
      :latest-webhook="latestWebhook"
      @done="onProposed"
    />
    <ImpersonationDialog
      v-if="impersonateOpen"
      :open="impersonateOpen"
      :merchant-id="payment.merchant.id"
      :merchant-name="payment.merchant.name"
      @update:open="(o: boolean) => { if (!o) impersonateOpen = false }"
    />
  </div>
</template>
