<script setup lang="ts">
import { useQuery } from "@tanstack/vue-query";
import { api } from "../api";
import { formatMoney } from "../../shared/money";

type Home = {
  needs_attention: Record<string, number>;
  volume_7d: Record<string, number>;
  balance: Record<string, number> | null;
};
const { data } = useQuery({ queryKey: ["home"], queryFn: () => api.get<Home>("/home") });
</script>

<template>
  <div
    v-if="data"
    class="space-y-6"
  >
    <h1 class="text-2xl font-semibold">
      Home
    </h1>
    <section aria-labelledby="attention">
      <h2
        id="attention"
        class="text-sm font-medium uppercase text-slate-500"
      >
        Needs attention
      </h2>
      <p
        v-if="Object.keys(data.needs_attention).length === 0"
        class="mt-2 text-slate-600"
      >
        Nothing needs attention.
      </p>
      <ul class="mt-2 flex gap-3">
        <li
          v-for="(count, state) in data.needs_attention"
          :key="state"
        >
          <RouterLink
            :to="{ path: '/payments', query: { state } }"
            class="block rounded border border-amber-300 bg-amber-50 px-4 py-3"
          >
            <span class="text-2xl font-semibold">{{ count }}</span>
            <span class="ml-2">{{ String(state).replaceAll("_", " ") }}</span>
          </RouterLink>
        </li>
      </ul>
    </section>
    <section aria-labelledby="volume">
      <h2
        id="volume"
        class="text-sm font-medium uppercase text-slate-500"
      >
        Volume, last 7 days
      </h2>
      <ul class="mt-2 flex gap-6 text-lg">
        <li
          v-for="(minor, currency) in data.volume_7d"
          :key="currency"
        >
          {{ formatMoney(minor, String(currency)) }}
        </li>
      </ul>
    </section>
    <section
      v-if="data.balance"
      aria-labelledby="balance"
    >
      <h2
        id="balance"
        class="text-sm font-medium uppercase text-slate-500"
      >
        Available balance
      </h2>
      <ul class="mt-2 flex gap-6 text-lg">
        <li
          v-for="(minor, currency) in data.balance"
          :key="currency"
        >
          {{ formatMoney(minor, String(currency)) }}
        </li>
      </ul>
    </section>
  </div>
</template>
