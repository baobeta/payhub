<script setup lang="ts">
import { ref, watch } from "vue";
import { useQuery, useQueryClient } from "@tanstack/vue-query";
import { api } from "../api";
import { useMe } from "../useMe";
import { ApiFailure } from "../../shared/http";
import ErrorBanner from "../../shared/components/ErrorBanner.vue";
import OneTimeSecret from "../components/OneTimeSecret.vue";

type Endpoint = { url: string | null; livemode: boolean; secret_last4: string; previous_secret_expires_at: string | null };

const { allowed } = useMe();
const queryClient = useQueryClient();
const endpoint = useQuery({ queryKey: ["webhook-endpoint"], queryFn: () => api.get<Endpoint>("/webhook_endpoint") });
const url = ref("");
watch(() => endpoint.data.value?.url, (u) => (url.value = u ?? ""), { immediate: true });

const secret = ref<string | null>(null);
const error = ref<string | null>(null);
const saved = ref(false);

async function act(fn: () => Promise<{ secret?: string }>) {
  error.value = null;
  saved.value = false;
  try {
    const res = await fn();
    if (res.secret) secret.value = res.secret;
    saved.value = true;
  } catch (e) {
    error.value = e instanceof ApiFailure ? e.message : "Something went wrong. Try again.";
  } finally {
    queryClient.invalidateQueries({ queryKey: ["webhook-endpoint"] });
  }
}
</script>

<template>
  <div
    v-if="endpoint.data.value"
    class="max-w-2xl space-y-6"
  >
    <h1 class="text-2xl font-semibold">
      Webhooks <span class="text-base font-normal text-slate-500">({{ endpoint.data.value.livemode ? "live" : "test" }})</span>
    </h1>
    <form
      class="space-y-2"
      @submit.prevent="act(() => api.patch('/webhook_endpoint', { url }))"
    >
      <label class="block text-sm font-medium">Endpoint URL
        <input
          v-model="url"
          type="url"
          :disabled="!allowed('webhooks.manage')"
          placeholder="https://example.com/payhub/webhooks"
          class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
        >
      </label>
      <button
        v-if="allowed('webhooks.manage')"
        type="submit"
        class="rounded bg-slate-900 px-3 py-1.5 text-sm text-white"
      >
        Save
      </button>
      <span
        v-if="saved && !secret"
        class="ml-2 text-sm text-emerald-700"
      >Saved.</span>
    </form>
    <section class="space-y-2">
      <h2 class="text-lg font-semibold">
        Signing secret
      </h2>
      <p class="text-sm text-slate-600">
        Ends in <code>{{ endpoint.data.value.secret_last4 }}</code>.
        <template v-if="endpoint.data.value.previous_secret_expires_at">
          The previous secret also signs until {{ new Date(endpoint.data.value.previous_secret_expires_at).toLocaleString() }}.
        </template>
      </p>
      <div
        v-if="allowed('webhooks.manage')"
        class="flex gap-2"
      >
        <button
          type="button"
          class="rounded border border-slate-300 bg-white px-3 py-1.5 text-sm"
          @click="act(() => api.post('/webhook_endpoint/reveal_secret'))"
        >
          Reveal
        </button>
        <button
          type="button"
          class="rounded border border-slate-300 bg-white px-3 py-1.5 text-sm"
          @click="act(() => api.post('/webhook_endpoint/roll_secret'))"
        >
          Roll (old one keeps signing for 24 hours)
        </button>
      </div>
      <OneTimeSecret
        v-if="secret"
        label="Signing secret"
        :value="secret"
      />
    </section>
    <ErrorBanner :message="error" />
  </div>
</template>
