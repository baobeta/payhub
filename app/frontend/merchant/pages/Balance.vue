<script setup lang="ts">
import { useQuery } from "@tanstack/vue-query";
import { api } from "../api";
import { useMe } from "../useMe";
import { formatMoney } from "../../shared/money";

type Row = { currency: string; available_minor: number; reserved_minor: number };
type Settlement = { settled_on: string; currency: string; gross_minor: number; fee_minor: number; net_minor: number };

const { allowed } = useMe();
const balance = useQuery({ queryKey: ["balance"], queryFn: () => api.get<{ data: Row[] }>("/balance") });
const settlements = useQuery({
  queryKey: ["settlements"],
  queryFn: () => api.get<{ data: Settlement[] }>("/settlements"),
  enabled: () => allowed("settlements.read"),
});
</script>

<template>
  <div class="space-y-6">
    <h1 class="text-2xl font-semibold">
      Balance
    </h1>
    <table class="w-full max-w-xl rounded bg-white text-sm shadow-sm">
      <thead class="text-left text-slate-500">
        <tr>
          <th class="p-2">
            Currency
          </th>
          <th class="p-2">
            Available
          </th>
          <th class="p-2">
            Reserved for refunds
          </th>
        </tr>
      </thead>
      <tbody>
        <tr
          v-for="r in balance.data.value?.data ?? []"
          :key="r.currency"
          class="border-t border-slate-100"
        >
          <td class="p-2">
            {{ r.currency }}
          </td>
          <td class="p-2">
            {{ formatMoney(r.available_minor, r.currency) }}
          </td>
          <td class="p-2">
            {{ formatMoney(r.reserved_minor, r.currency) }}
          </td>
        </tr>
      </tbody>
    </table>
    <section
      v-if="allowed('settlements.read')"
      aria-labelledby="settlements"
    >
      <h2
        id="settlements"
        class="mb-2 text-lg font-semibold"
      >
        Settlements
      </h2>
      <table class="w-full rounded bg-white text-sm shadow-sm">
        <thead class="text-left text-slate-500">
          <tr>
            <th class="p-2">
              Day
            </th>
            <th class="p-2">
              Gross
            </th>
            <th class="p-2">
              PSP fees
            </th>
            <th class="p-2">
              Net
            </th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="s in settlements.data.value?.data ?? []"
            :key="s.settled_on + s.currency"
            class="border-t border-slate-100"
          >
            <td class="p-2">
              {{ s.settled_on }}
            </td>
            <td class="p-2">
              {{ formatMoney(s.gross_minor, s.currency) }}
            </td>
            <td class="p-2">
              {{ formatMoney(s.fee_minor, s.currency) }}
            </td>
            <td class="p-2">
              {{ formatMoney(s.net_minor, s.currency) }}
            </td>
          </tr>
        </tbody>
      </table>
    </section>
  </div>
</template>
