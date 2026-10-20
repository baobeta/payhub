<script setup lang="ts">
import { computed, ref, watch } from "vue";
import BaseModal from "../../shared/components/BaseModal.vue";
import ErrorBanner from "../../shared/components/ErrorBanner.vue";
import { api } from "../api";
import { ApiFailure } from "../../shared/http";
import { useIdempotencyKey } from "../../shared/useIdempotencyKey";
import { formatMoney, minorToInput, toMinor } from "../../shared/money";

const props = defineProps<{ open: boolean; paymentId: string; currency: string; capturableMinor: number }>();
const emit = defineEmits<{ "update:open": [boolean]; done: [] }>();

const { key, renew } = useIdempotencyKey();
const amount = ref("");
// Final by default, as the API: a final capture closes capturing, and the
// uncaptured rest of the hold lapses at the card network (DECISIONS #20).
const final = ref(true);
const error = ref<string | null>(null);
const submitting = ref(false);

watch(
  () => props.open,
  (open) => {
    if (!open) return;
    renew();
    amount.value = minorToInput(props.capturableMinor, props.currency);
    final.value = true;
    error.value = null;
  },
  { immediate: true },
);

const amountMinor = computed(() => toMinor(amount.value, props.currency));
const valid = computed(() => amountMinor.value > 0 && amountMinor.value <= props.capturableMinor);

async function submit() {
  submitting.value = true;
  error.value = null;
  try {
    await api.post(`/payments/${props.paymentId}/capture`, { amount_minor: amountMinor.value, final: final.value }, { idempotencyKey: key.value });
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
    title="Capture payment"
    description="Partial capture is allowed. After the final capture nothing more can be captured, and the rest of the hold lapses at the customer's bank; PayHub does not release it early."
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
        >
      </label>
      <p class="text-sm text-slate-600">
        Up to {{ formatMoney(capturableMinor, currency) }} can be captured.
      </p>
      <label class="flex items-center gap-2 text-sm text-slate-700">
        <input
          v-model="final"
          type="checkbox"
        >
        This is the final capture
      </label>
      <ErrorBanner :message="error" />
      <button
        type="submit"
        :disabled="!valid || submitting"
        class="w-full rounded bg-slate-900 px-3 py-2 text-white disabled:opacity-50"
      >
        Capture
      </button>
    </form>
  </BaseModal>
</template>
