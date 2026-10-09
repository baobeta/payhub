<script setup lang="ts">
import { computed, ref } from "vue";
import { useQuery, useQueryClient } from "@tanstack/vue-query";
import { api } from "../api";
import { ApiFailure } from "../../shared/http";
import ErrorBanner from "../../shared/components/ErrorBanner.vue";
import type { List, OperatorRow } from "../types";

const ROLES = ["support", "ops", "approver", "admin"];
const queryClient = useQueryClient();
const list = useQuery({ queryKey: ["ops-operators"], queryFn: () => api.get<List<OperatorRow>>("/operators") });

const inviteEmail = ref("");
const inviteRole = ref("support");
const error = ref<string | null>(null);
const busy = ref(false);

const active = computed(() => (list.data.value?.data ?? []).filter((o) => !o.disabled_at));

async function run(fn: () => Promise<unknown>) {
  busy.value = true;
  error.value = null;
  try {
    await fn();
    await queryClient.invalidateQueries({ queryKey: ["ops-operators"] });
  } catch (e) {
    error.value = e instanceof ApiFailure ? e.message : "Something went wrong. Try again.";
  } finally {
    busy.value = false;
  }
}

function invite() {
  run(async () => {
    await api.post("/operators", { email: inviteEmail.value, role: inviteRole.value });
    inviteEmail.value = "";
  });
}

function changeRole(o: OperatorRow, role: string) {
  run(() => api.patch(`/operators/${o.id}`, { role }));
}

function disable(o: OperatorRow) {
  run(() => api.delete(`/operators/${o.id}`));
}
</script>

<template>
  <div class="space-y-6">
    <div class="flex items-center gap-3">
      <h1 class="text-2xl font-semibold">
        Operators
      </h1>
      <a
        href="/ops/api/access_review"
        class="ml-auto rounded border border-slate-300 bg-white px-3 py-1.5 text-sm"
      >
        Export access review
      </a>
    </div>

    <form
      class="flex flex-wrap items-end gap-2 rounded bg-white p-3 shadow-sm"
      @submit.prevent="invite"
    >
      <label class="text-sm font-medium text-slate-700">
        Email
        <input
          v-model="inviteEmail"
          type="email"
          required
          class="mt-1 block rounded border border-slate-300 px-3 py-2"
        >
      </label>
      <label class="text-sm font-medium text-slate-700">
        Role
        <select
          v-model="inviteRole"
          class="mt-1 block rounded border border-slate-300 px-3 py-2"
        >
          <option
            v-for="r in ROLES"
            :key="r"
            :value="r"
          >{{ r }}</option>
        </select>
      </label>
      <button
        type="submit"
        :disabled="busy || inviteEmail.trim() === ''"
        class="rounded bg-slate-900 px-4 py-2 text-white disabled:opacity-50"
      >
        Invite
      </button>
    </form>

    <ErrorBanner :message="error" />

    <table class="w-full rounded bg-white text-sm shadow-sm">
      <thead class="text-left text-slate-500">
        <tr>
          <th class="p-2">
            Email
          </th><th class="p-2">
            Role
          </th><th class="p-2">
            Last sign-in
          </th><th class="p-2" />
        </tr>
      </thead>
      <tbody>
        <tr
          v-for="o in active"
          :key="o.id"
          class="border-t border-slate-100"
        >
          <td class="p-2">
            {{ o.email }}
          </td>
          <td class="p-2">
            <select
              :value="o.role"
              class="rounded border border-slate-300 px-2 py-1"
              :disabled="busy"
              @change="changeRole(o, ($event.target as HTMLSelectElement).value)"
            >
              <option
                v-for="r in ROLES"
                :key="r"
                :value="r"
              >
                {{ r }}
              </option>
            </select>
          </td>
          <td class="p-2">
            {{ o.last_sign_in_at ? new Date(o.last_sign_in_at).toLocaleString() : "never" }}
          </td>
          <td class="p-2 text-right">
            <button
              type="button"
              class="text-red-700 underline disabled:opacity-50"
              :disabled="busy"
              @click="disable(o)"
            >
              Disable
            </button>
          </td>
        </tr>
      </tbody>
    </table>
    <p
      v-if="list.data.value && active.length === 0"
      class="text-slate-600"
    >
      No active operator.
    </p>
  </div>
</template>
