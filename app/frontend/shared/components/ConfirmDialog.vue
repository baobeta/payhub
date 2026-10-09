<script setup lang="ts">
import { computed, ref, watch } from "vue";
import BaseModal from "../../shared/components/BaseModal.vue";
import ErrorBanner from "../../shared/components/ErrorBanner.vue";

// For irreversible actions: the person types a word (e.g. the key name) to
// confirm, so a stray click cannot revoke or remove anything.
const props = defineProps<{
  open: boolean;
  title: string;
  description: string;
  confirmLabel: string;
  typeToConfirm?: string;
  error?: string | null;
  busy?: boolean;
}>();
const emit = defineEmits<{ "update:open": [boolean]; confirm: [] }>();
const typed = ref("");
watch(() => props.open, () => (typed.value = ""));
const ready = computed(() => !props.typeToConfirm || typed.value === props.typeToConfirm);
</script>

<template>
  <BaseModal
    :open="open"
    :title="title"
    :description="description"
    @update:open="emit('update:open', $event)"
  >
    <form
      class="space-y-3"
      @submit.prevent="emit('confirm')"
    >
      <label
        v-if="typeToConfirm"
        class="block text-sm font-medium text-slate-700"
      >
        Type <strong>{{ typeToConfirm }}</strong> to confirm
        <input
          v-model="typed"
          class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
        >
      </label>
      <ErrorBanner :message="error ?? null" />
      <button
        type="submit"
        :disabled="!ready || busy"
        class="w-full rounded bg-red-700 px-3 py-2 text-white disabled:opacity-50"
      >
        {{ confirmLabel }}
      </button>
    </form>
  </BaseModal>
</template>
