<script setup lang="ts">
import { ref, watch } from "vue";
import { useQueryClient } from "@tanstack/vue-query";
import { useRouter } from "vue-router";
import BaseModal from "../../shared/components/BaseModal.vue";
import ErrorBanner from "../../shared/components/ErrorBanner.vue";
import { api } from "../api";
import { ApiFailure } from "../../shared/http";
import type { OpsMe } from "../types";

const props = defineProps<{ open: boolean; merchantId: string; merchantName: string }>();
const emit = defineEmits<{ "update:open": [boolean] }>();

const queryClient = useQueryClient();
const router = useRouter();
const caseRef = ref("");
const error = ref<string | null>(null);
const busy = ref(false);

watch(() => props.open, (open) => {
  if (open) {
    caseRef.value = "";
    error.value = null;
  }
});

async function start() {
  busy.value = true;
  error.value = null;
  try {
    const res = await api.post<{ merchant_id: string; expires_at: string }>("/impersonations", {
      merchant_id: props.merchantId,
      case_reference: caseRef.value,
    });
    queryClient.setQueryData<OpsMe>(["me"], (old) => (old
      ? { ...old, impersonating: { merchant_id: res.merchant_id, merchant_name: props.merchantName, case_ref: caseRef.value, expires_at: res.expires_at } }
      : old));
    emit("update:open", false);
    router.push(`/as/${res.merchant_id}`);
  } catch (e) {
    error.value = e instanceof ApiFailure ? e.message : "Could not start the session. Try again.";
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <BaseModal
    :open="open"
    title="View as this merchant?"
    description="You will see their dashboard read-only for up to 30 minutes. The merchant sees this in their security history."
    @update:open="emit('update:open', $event)"
  >
    <form
      class="space-y-3"
      @submit.prevent="start"
    >
      <label class="block text-sm font-medium text-slate-700">
        Case reference
        <input
          v-model="caseRef"
          required
          placeholder="OPS-42"
          class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
        >
      </label>
      <ErrorBanner :message="error" />
      <button
        type="submit"
        :disabled="busy || caseRef.trim() === ''"
        class="w-full rounded bg-red-700 px-3 py-2 text-white disabled:opacity-50"
      >
        Start read-only session
      </button>
    </form>
  </BaseModal>
</template>
