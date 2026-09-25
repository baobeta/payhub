<script setup lang="ts">
import type { TimelineEntry } from "../types";
import { formatMoney } from "../../shared/money";

const props = defineProps<{ entries: TimelineEntry[]; currency: string }>();

function describe(e: TimelineEntry): string {
  switch (e.kind) {
    case "transition":
      return `${e.from ?? "created"} → ${e.to} (${e.source})${e.applied === false ? " — ignored, a newer PSP event exists" : ""}`;
    case "capture":
      return `Capture of ${formatMoney(e.amount_minor as number, props.currency)}: ${e.state}`;
    case "refund":
      return `Refund of ${formatMoney(e.amount_minor as number, props.currency)}: ${e.state}${e.reason ? ` (${String(e.reason).replaceAll("_", " ")})` : ""}`;
    case "ledger_transfer":
      return (e.legs as { account: string; direction: string; amount_minor: number }[])
        .map((l) => `${l.direction} ${l.account.replaceAll("_", " ")} ${formatMoney(l.amount_minor, props.currency)}`)
        .join(" · ");
    case "event":
      return `Webhook ${e.type}: ${e.state} after ${e.attempts} attempt(s)`;
  }
}

const LABEL: Record<TimelineEntry["kind"], string> = {
  transition: "State",
  capture: "Capture",
  refund: "Refund",
  ledger_transfer: "Ledger",
  event: "Webhook",
};
</script>

<template>
  <ol class="relative space-y-3 border-l border-slate-200 pl-4">
    <li
      v-for="(e, i) in entries"
      :key="i"
      class="text-sm"
    >
      <span class="absolute -left-1.5 mt-1.5 h-3 w-3 rounded-full border border-white bg-slate-400" />
      <time
        class="block text-xs text-slate-500"
        :datetime="e.at"
      >{{ new Date(e.at).toLocaleString() }}</time>
      <span class="mr-2 font-medium text-slate-700">{{ LABEL[e.kind] }}</span>
      <span class="text-slate-800">{{ describe(e) }}</span>
    </li>
  </ol>
</template>
