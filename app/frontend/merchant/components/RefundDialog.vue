<script setup lang="ts">
import { computed, ref, watch } from "vue";
import BaseModal from "../../shared/components/BaseModal.vue";
import ErrorBanner from "../../shared/components/ErrorBanner.vue";
import { api } from "../api";
import { ApiFailure } from "../../shared/http";
import { useIdempotencyKey } from "../../shared/useIdempotencyKey";
import { formatMoney, minorToInput, toMinor } from "../../shared/money";

const props = defineProps<{ open: boolean; paymentId: string; currency: string; refundableMinor: number }>();
const emit = defineEmits<{ "update:open": [boolean]; done: [] }>();

const { key, renew } = useIdempotencyKey();
const amount = ref("");
const reason = ref("");
const error = ref<string | null>(null);
const submitting = ref(false);

// A new intent each time the modal opens; retries of one submit reuse the key.
watch(
  () => props.open,
  (open) => {
    if (!open) return;
    renew();
    amount.value = minorToInput(props.refundableMinor, props.currency);
    reason.value = "";
    error.value = null;
  },
  { immediate: true },
);

const amountMinor = computed(() => toMinor(amount.value, props.currency));
const valid = computed(() => amountMinor.value > 0 && amountMinor.value <= props.refundableMinor && reason.value !== "");

async function submit() {
  submitting.value = true;
  error.value = null;
  try {
    await api.post(`/payments/${props.paymentId}/refunds`, { amount_minor: amountMinor.value, reason: reason.value }, { idempotencyKey: key.value });
    emit("done");
    emit("update:open", false);
  } catch (e) {
    error.value = e instanceof ApiFailure ? e.message : "Something went wrong. Try again.";
  } finally {
    submitting.value = false;
  }
}
</script>

<template>
  <BaseModal
    :open="open"
    title="Refund payment"
    @update:open="emit('update:open', $event)"
  >
    <form
      class="space-y-3"
      @submit.prevent="submit"
    >
      <label class="block text-sm font-medium text-slate-700">
        Amount ({{ currency }})
        <input
          v-model="amount"
          inputmode="decimal"
          class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          data-testid="refund-amount"
        >
      </label>
      <p class="text-sm text-slate-600">
        Up to {{ formatMoney(refundableMinor, currency) }} can be refunded.
      </p>
      <label class="block text-sm font-medium text-slate-700">
        Reason
        <select
          v-model="reason"
          class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          data-testid="refund-reason"
        >
          <option
            value=""
            disabled
          >Choose a reason</option>
          <option value="requested_by_customer">Requested by customer</option>
          <option value="duplicate">Duplicate</option>
          <option value="fraudulent">Fraudulent</option>
          <option value="other">Other</option>
        </select>
      </label>
      <ErrorBanner :message="error" />
      <button
        type="submit"
        :disabled="!valid || submitting"
        class="w-full rounded bg-red-700 px-3 py-2 text-white disabled:opacity-50"
        data-testid="refund-submit"
      >
        Refund {{ Number.isNaN(amountMinor) ? "" : formatMoney(amountMinor, currency) }}
      </button>
    </form>
  </BaseModal>
</template>
