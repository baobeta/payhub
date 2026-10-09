<script setup lang="ts">
import { computed, ref, watch } from "vue";
import BaseModal from "../../shared/components/BaseModal.vue";
import ErrorBanner from "../../shared/components/ErrorBanner.vue";
import { api } from "../api";
import { ApiFailure } from "../../shared/http";
import { useIdempotencyKey } from "../../shared/useIdempotencyKey";
import type { InboundEvent, Proposal, PspCall } from "../types";

const props = defineProps<{
  open: boolean;
  paymentId: string;
  currentState: string;
  latestCall?: PspCall | null;
  latestWebhook?: InboundEvent | null;
}>();
const emit = defineEmits<{ "update:open": [boolean]; done: [Proposal] }>();

const { key, renew } = useIdempotencyKey();
const toState = ref("failed");
const reasonCode = ref("psp_confirmed_outcome");
const reasonText = ref("");
const caseReference = ref("");
const error = ref<string | null>(null);
const busy = ref(false);

const REASONS = ["psp_confirmed_outcome", "psp_unreachable_timeout", "duplicate_booking", "ledger_error", "other"];
const targets = computed(() => (props.currentState === "unknown" ? ["authorized", "failed"] : []));
const valid = computed(() => targets.value.includes(toState.value) && reasonText.value.trim() !== "" && caseReference.value.trim() !== "");

watch(() => props.open, (open) => {
  if (!open) return;
  renew();
  toState.value = targets.value.includes("failed") ? "failed" : (targets.value[0] ?? "failed");
  reasonCode.value = "psp_confirmed_outcome";
  reasonText.value = "";
  caseReference.value = "";
  error.value = null;
});

async function submit() {
  busy.value = true;
  error.value = null;
  try {
    const proposal = await api.post<Proposal>("/proposals", {
      kind: "payment_transition",
      payment_id: props.paymentId,
      payload: { to_state: toState.value },
      reason_code: reasonCode.value,
      reason_text: reasonText.value,
      case_reference: caseReference.value,
      client_token: key.value,
    });
    emit("done", proposal);
    emit("update:open", false);
  } catch (e) {
    error.value = e instanceof ApiFailure ? e.message : "Something went wrong. Try again.";
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <BaseModal
    :open="open"
    title="Propose a resolution"
    description="A second operator must approve it before anything changes."
    @update:open="emit('update:open', $event)"
  >
    <div class="grid gap-4 md:grid-cols-2">
      <form
        class="space-y-3"
        @submit.prevent="submit"
      >
        <label class="block text-sm font-medium text-slate-700">
          Move to
          <select
            v-model="toState"
            class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          >
            <option
              v-for="t in targets"
              :key="t"
              :value="t"
            >{{ t }}</option>
          </select>
        </label>
        <label class="block text-sm font-medium text-slate-700">
          Reason code
          <select
            v-model="reasonCode"
            class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          >
            <option
              v-for="r in REASONS"
              :key="r"
              :value="r"
            >{{ r.replaceAll("_", " ") }}</option>
          </select>
        </label>
        <label class="block text-sm font-medium text-slate-700">
          What did you find?
          <textarea
            v-model="reasonText"
            rows="3"
            class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          />
        </label>
        <label class="block text-sm font-medium text-slate-700">
          Case reference
          <input
            v-model="caseReference"
            placeholder="OPS-42"
            class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          >
        </label>
        <ErrorBanner :message="error" />
        <button
          type="submit"
          :disabled="!valid || busy"
          class="w-full rounded bg-slate-900 px-3 py-2 text-white disabled:opacity-50"
        >
          Propose
        </button>
      </form>
      <aside class="space-y-3 rounded bg-slate-50 p-3 text-xs">
        <h3 class="text-sm font-medium">
          Evidence
        </h3>
        <div v-if="latestCall">
          <p class="font-medium">
            Last PSP call
          </p>
          <p>
            {{ latestCall.operation }} → {{ latestCall.outcome }}
            <template v-if="latestCall.http_status">
              (HTTP {{ latestCall.http_status }})
            </template>
          </p>
          <p class="text-slate-500">
            {{ new Date(latestCall.sent_at).toLocaleString() }}
          </p>
        </div>
        <p v-else>
          No PSP call recorded.
        </p>
        <div v-if="latestWebhook">
          <p class="font-medium">
            Last webhook
          </p>
          <p>{{ latestWebhook.event_type }} · signature {{ latestWebhook.signature_valid ? "valid" : "INVALID" }}</p>
          <p class="text-slate-500">
            {{ new Date(latestWebhook.received_at).toLocaleString() }}
          </p>
        </div>
        <p v-else>
          No webhook recorded.
        </p>
      </aside>
    </div>
  </BaseModal>
</template>
