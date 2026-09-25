<script setup lang="ts">
import { ref } from "vue";

// A secret the server will never show again (API key, webhook secret,
// recovery codes).
const props = defineProps<{ label: string; value: string }>();
const copied = ref(false);

async function copy() {
  await navigator.clipboard?.writeText(props.value);
  copied.value = true;
}
</script>

<template>
  <div class="rounded border border-amber-300 bg-amber-50 p-3">
    <p class="text-sm font-medium text-amber-900">
      {{ label }}: this is the only time you will see it.
    </p>
    <div class="mt-2 flex gap-2">
      <code class="flex-1 overflow-x-auto rounded bg-white px-2 py-1 font-mono text-sm">{{ value }}</code>
      <button
        type="button"
        class="rounded border border-slate-300 bg-white px-2 text-sm"
        @click="copy"
      >
        {{ copied ? "Copied" : "Copy" }}
      </button>
    </div>
  </div>
</template>
