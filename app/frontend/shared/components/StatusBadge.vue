<script setup lang="ts">
import { computed } from "vue";

// Text always carries the meaning; colour only reinforces it.
const props = defineProps<{ status: string }>();
const tone = computed(() => {
  if (["captured", "succeeded", "delivered", "active", "authorized", "success", "applied"].includes(props.status)) return "bg-emerald-50 text-emerald-800 ring-emerald-200";
  if (["failed", "canceled", "dead", "revoked", "expired", "removed", "denied", "failure"].includes(props.status)) return "bg-red-50 text-red-800 ring-red-200";
  if (["unknown", "requires_action", "expiring", "invited"].includes(props.status)) return "bg-amber-50 text-amber-900 ring-amber-200";
  return "bg-slate-100 text-slate-700 ring-slate-200";
});
</script>

<template>
  <span
    class="inline-flex items-center rounded px-2 py-0.5 text-xs font-medium ring-1 ring-inset"
    :class="tone"
  >{{ status.replaceAll("_", " ") }}</span>
</template>
