<script setup lang="ts">
import { ref, watch } from "vue";
import BaseModal from "./BaseModal.vue";
import ErrorBanner from "./ErrorBanner.vue";
import { ApiFailure, type ApiClient } from "../http";
import { finishStepUp, stepUpState } from "../stepUp";

const props = defineProps<{ client: ApiClient }>();
const code = ref("");
const error = ref<string | null>(null);
const busy = ref(false);

watch(() => stepUpState.open, (open) => {
  if (open) {
    code.value = "";
    error.value = null;
  }
});

async function confirm() {
  busy.value = true;
  error.value = null;
  try {
    await props.client.post("/session/step_up", { code: code.value });
    finishStepUp(true);
  } catch (e) {
    error.value = e instanceof ApiFailure ? e.message : "Could not confirm. Try again.";
  } finally {
    busy.value = false;
  }
}

function onOpenChange(open: boolean) {
  if (!open) finishStepUp(false);
}
</script>

<template>
  <BaseModal
    :open="stepUpState.open"
    title="Confirm it's you"
    description="This action is sensitive. Enter the 6-digit code from your authenticator app."
    @update:open="onOpenChange"
  >
    <form
      class="space-y-3"
      @submit.prevent="confirm"
    >
      <label class="block text-sm font-medium text-slate-700">
        Authenticator code
        <input
          v-model="code"
          inputmode="numeric"
          autocomplete="one-time-code"
          maxlength="6"
          class="mt-1 w-full rounded border border-slate-300 px-3 py-2 tracking-widest"
        >
      </label>
      <ErrorBanner :message="error" />
      <button
        type="submit"
        :disabled="code.length !== 6 || busy"
        class="w-full rounded bg-slate-900 px-3 py-2 text-white disabled:opacity-50"
      >
        Confirm
      </button>
    </form>
  </BaseModal>
</template>
