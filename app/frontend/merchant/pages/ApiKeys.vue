<script setup lang="ts">
import { ref, watch } from "vue";
import { useQuery, useQueryClient } from "@tanstack/vue-query";
import { api } from "../api";
import { useMe } from "../useMe";
import { ApiFailure } from "../../shared/http";
import BaseModal from "../../shared/components/BaseModal.vue";
import ErrorBanner from "../../shared/components/ErrorBanner.vue";
import StatusBadge from "../../shared/components/StatusBadge.vue";
import ConfirmDialog from "../components/ConfirmDialog.vue";
import OneTimeSecret from "../components/OneTimeSecret.vue";

type Key = {
  id: string; name: string; note: string | null; redacted: string; status: string;
  created_by: string | null; created_at: string; last_used_at: string | null; expires_at: string | null;
};

const { data: me, allowed } = useMe();
const queryClient = useQueryClient();
const keys = useQuery({ queryKey: ["api-keys"], queryFn: () => api.get<{ data: Key[] }>("/api_keys") });

const secret = ref<string | null>(null);
// A secret belongs to the mode it was shown in; never leave it on screen under the other.
watch(() => me.value?.livemode, () => (secret.value = null));
const error = ref<string | null>(null);
const createOpen = ref(false);
const name = ref("");
const note = ref("");
const rolling = ref<Key | null>(null);
const expiresIn = ref("24h");
const revoking = ref<Key | null>(null);

async function run(fn: () => Promise<{ secret?: string }>) {
  error.value = null;
  try {
    const res = await fn();
    secret.value = res.secret ?? null;
    createOpen.value = false;
    rolling.value = null;
    revoking.value = null;
  } catch (e) {
    error.value = e instanceof ApiFailure ? e.message : "Something went wrong. Try again.";
  } finally {
    queryClient.invalidateQueries({ queryKey: ["api-keys"] });
  }
}

const create = () => run(() => api.post("/api_keys", { name: name.value, note: note.value || null }));
const roll = () => run(() => api.post(`/api_keys/${rolling.value!.id}/roll`, { expires_in: expiresIn.value }));
const revoke = () => run(() => api.post(`/api_keys/${revoking.value!.id}/revoke`));
</script>

<template>
  <div class="space-y-4">
    <div class="flex items-center">
      <h1 class="text-2xl font-semibold">
        API keys <span class="text-base font-normal text-slate-500">({{ me?.livemode ? "live" : "test" }})</span>
      </h1>
      <button
        v-if="allowed('api_keys.manage')"
        type="button"
        class="ml-auto rounded bg-slate-900 px-3 py-1.5 text-sm text-white"
        @click="createOpen = true; name = ''; note = ''"
      >
        Create key
      </button>
    </div>
    <OneTimeSecret
      v-if="secret"
      label="Secret key"
      :value="secret"
    />
    <ErrorBanner :message="error" />
    <table class="w-full rounded bg-white text-sm shadow-sm">
      <thead class="text-left text-slate-500">
        <tr>
          <th class="p-2">
            Name
          </th><th class="p-2">
            Key
          </th><th class="p-2">
            Status
          </th>
          <th class="p-2">
            Last used
          </th><th class="p-2">
            Created by
          </th><th class="p-2" />
        </tr>
      </thead>
      <tbody>
        <tr
          v-for="k in keys.data.value?.data ?? []"
          :key="k.id"
          class="border-t border-slate-100"
        >
          <td class="p-2">
            {{ k.name }}<span
              v-if="k.note"
              class="block text-xs text-slate-500"
            >{{ k.note }}</span>
          </td>
          <td class="p-2 font-mono text-xs">
            {{ k.redacted }}
          </td>
          <td class="p-2">
            <StatusBadge :status="k.status" /><span
              v-if="k.expires_at && k.status === 'expiring'"
              class="ml-1 text-xs"
            >until {{ new Date(k.expires_at).toLocaleString() }}</span>
          </td>
          <td class="p-2">
            {{ k.last_used_at ? new Date(k.last_used_at).toLocaleString() : "never" }}
          </td>
          <td class="p-2">
            {{ k.created_by ?? "—" }}
          </td>
          <td class="p-2 text-right">
            <template v-if="allowed('api_keys.manage') && k.status === 'active'">
              <button
                type="button"
                class="mr-2 underline"
                @click="rolling = k; expiresIn = '24h'"
              >
                Roll
              </button>
              <button
                type="button"
                class="text-red-700 underline"
                @click="revoking = k"
              >
                Revoke
              </button>
            </template>
          </td>
        </tr>
      </tbody>
    </table>
    <BaseModal
      v-model:open="createOpen"
      title="Create API key"
    >
      <form
        class="space-y-3"
        @submit.prevent="create"
      >
        <label class="block text-sm font-medium">Name
          <input
            v-model="name"
            required
            class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          >
        </label>
        <label class="block text-sm font-medium">Where is it stored? (optional)
          <input
            v-model="note"
            class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          >
        </label>
        <button
          type="submit"
          :disabled="!name"
          class="w-full rounded bg-slate-900 px-3 py-2 text-white disabled:opacity-50"
        >
          Create
        </button>
      </form>
    </BaseModal>
    <BaseModal
      :open="!!rolling"
      title="Roll API key"
      description="A new key replaces this one. Keep the old one working while you deploy the new one."
      @update:open="(o: boolean) => { if (!o) rolling = null }"
    >
      <form
        class="space-y-3"
        @submit.prevent="roll"
      >
        <fieldset class="space-y-1 text-sm">
          <legend class="font-medium">
            Old key keeps working for
          </legend>
          <label class="block"><input
            v-model="expiresIn"
            type="radio"
            value="now"
          > No time: revoke it now</label>
          <label class="block"><input
            v-model="expiresIn"
            type="radio"
            value="24h"
          > 24 hours</label>
          <label class="block"><input
            v-model="expiresIn"
            type="radio"
            value="7d"
          > 7 days</label>
        </fieldset>
        <button
          type="submit"
          class="w-full rounded bg-slate-900 px-3 py-2 text-white"
        >
          Roll key
        </button>
      </form>
    </BaseModal>
    <ConfirmDialog
      :open="!!revoking"
      title="Revoke this key?"
      description="Requests using it fail immediately. This cannot be undone."
      confirm-label="Revoke key"
      :type-to-confirm="revoking?.name"
      @update:open="(o: boolean) => { if (!o) revoking = null }"
      @confirm="revoke"
    />
  </div>
</template>
