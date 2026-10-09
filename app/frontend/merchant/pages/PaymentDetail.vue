<script setup lang="ts">
import { computed, ref } from "vue";
import { useQueryClient } from "@tanstack/vue-query";
import { useRoute } from "vue-router";
import { api } from "../api";
import { ApiFailure } from "../../shared/http";
import { useLiveQuery } from "../../shared/useLiveQuery";
import { pollIntervalFor } from "../../shared/pollInterval";
import { useIdempotencyKey } from "../../shared/useIdempotencyKey";
import { formatMoney } from "../../shared/money";
import StatusBadge from "../../shared/components/StatusBadge.vue";
import ErrorBanner from "../../shared/components/ErrorBanner.vue";
import PaymentTimeline from "../components/PaymentTimeline.vue";
import RefundDialog from "../components/RefundDialog.vue";
import CaptureDialog from "../components/CaptureDialog.vue";
import ConfirmDialog from "../components/ConfirmDialog.vue";
import type { PaymentDetail } from "../types";

const route = useRoute();
const queryClient = useQueryClient();
const id = computed(() => String(route.params.id));
const key = computed(() => ["payment", id.value]);

const { data: payment, isError } = useLiveQuery<PaymentDetail>(
  key,
  (poll) => api.get(`/payments/${id.value}`, { poll }),
  (p) => pollIntervalFor(p.state),
);

const refundOpen = ref(false);
const captureOpen = ref(false);
const cancelOpen = ref(false);
const cancelError = ref<string | null>(null);
const cancelBusy = ref(false);
const cancelKey = useIdempotencyKey();

function refresh() {
  queryClient.invalidateQueries({ queryKey: key.value });
}

function openCancel() {
  cancelKey.renew();
  cancelError.value = null;
  cancelOpen.value = true;
}

async function cancel() {
  cancelBusy.value = true;
  try {
    await api.post(`/payments/${id.value}/cancel`, {}, { idempotencyKey: cancelKey.key.value });
    cancelOpen.value = false;
  } catch (e) {
    // 409/422: someone (or the sweeper) moved it first. Show why and refetch.
    cancelError.value = e instanceof ApiFailure ? e.message : "Something went wrong. Try again.";
  } finally {
    cancelBusy.value = false;
    refresh();
  }
}

const lastCheck = computed(() => payment.value?.updated_at && new Date(payment.value.updated_at).toLocaleTimeString());
</script>

<template>
  <p
    v-if="isError"
    role="alert"
  >
    This payment does not exist in the current mode.
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
      <div class="ml-auto flex gap-2">
        <button
          v-if="payment.can.capture"
          type="button"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm text-white"
          @click="captureOpen = true"
        >
          Capture
        </button>
        <button
          v-if="payment.can.cancel"
          type="button"
          class="rounded border border-slate-300 bg-white px-3 py-1.5 text-sm"
          @click="openCancel"
        >
          Cancel
        </button>
        <button
          v-if="payment.can.refund"
          type="button"
          class="rounded bg-red-700 px-3 py-1.5 text-sm text-white"
          @click="refundOpen = true"
        >
          Refund
        </button>
      </div>
    </div>
    <p
      v-if="payment.state === 'unknown'"
      class="rounded border border-amber-300 bg-amber-50 p-3 text-sm"
    >
      We are confirming this payment with the PSP. It was last updated at {{ lastCheck }}; this page refreshes by itself.
    </p>
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
    <ErrorBanner :message="cancelError" />
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
    <RefundDialog
      v-model:open="refundOpen"
      :payment-id="payment.id"
      :currency="payment.currency"
      :refundable-minor="payment.can.refundable_minor"
      @done="refresh"
    />
    <CaptureDialog
      v-model:open="captureOpen"
      :payment-id="payment.id"
      :currency="payment.currency"
      :capturable-minor="payment.can.capturable_minor"
      @done="refresh"
    />
    <ConfirmDialog
      v-model:open="cancelOpen"
      title="Cancel this payment?"
      description="This releases the authorization. The customer is not charged. It cannot be undone."
      confirm-label="Cancel payment"
      :error="cancelError"
      :busy="cancelBusy"
      @confirm="cancel"
    />
  </div>
</template>
