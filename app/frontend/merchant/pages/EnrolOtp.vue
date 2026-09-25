<script setup lang="ts">
import { ref } from "vue";
import { useQuery, useQueryClient } from "@tanstack/vue-query";
import { useRouter } from "vue-router";
import { api } from "../api";
import { ApiFailure } from "../../shared/http";
import ErrorBanner from "../../shared/components/ErrorBanner.vue";
import type { Me } from "../types";

const router = useRouter();
const queryClient = useQueryClient();
const setup = useQuery({
  queryKey: ["otp-setup"],
  queryFn: () => api.get<{ provisioning_uri: string; qr_svg: string }>("/otp/setup"),
});

const code = ref("");
const error = ref<string | null>(null);
const busy = ref(false);
const codes = ref<string[] | null>(null);
const saved = ref(false);
let me: Me | null = null;

async function confirm() {
  busy.value = true;
  error.value = null;
  try {
    const res = await api.post<Me & { recovery_codes: string[] }>("/otp/confirm", { code: code.value });
    codes.value = res.recovery_codes;
    me = res;
  } catch (e) {
    error.value = e instanceof ApiFailure ? e.message : "Something went wrong. Try again.";
  } finally {
    busy.value = false;
  }
}

function finish() {
  if (me) queryClient.setQueryData(["me"], me);
  router.push("/");
}
</script>

<template>
  <main class="flex min-h-screen items-center justify-center bg-slate-50 p-4">
    <div class="w-full max-w-md rounded-lg bg-white p-6 shadow">
      <template v-if="!codes">
        <h1 class="text-xl font-semibold">
          Set up your authenticator app
        </h1>
        <p
          v-if="setup.isError.value"
          role="alert"
          class="mt-3"
        >
          Your setup session expired. Open your invitation link again.
        </p>
        <template v-else-if="setup.data.value">
          <p class="mt-1 text-sm text-slate-600">
            Scan this code with Google Authenticator, 1Password or a similar app. Two-factor sign-in is required.
          </p>
          <!-- Server-generated SVG from rqrcode; contains no user input. -->
          <!-- eslint-disable vue/no-v-html -->
          <div
            class="mx-auto mt-4 w-48"
            role="img"
            aria-label="QR code for your authenticator app"
            v-html="setup.data.value.qr_svg"
          />
          <!-- eslint-enable vue/no-v-html -->
          <details class="mt-2 text-sm">
            <summary>Can't scan it?</summary>
            <code class="break-all">{{ setup.data.value.provisioning_uri }}</code>
          </details>
          <form
            class="mt-4 space-y-3"
            @submit.prevent="confirm"
          >
            <label class="block text-sm font-medium text-slate-700">
              Authenticator code
              <input
                v-model="code"
                inputmode="numeric"
                autocomplete="one-time-code"
                maxlength="6"
                class="mt-1 w-full rounded border border-slate-300 px-3 py-2 tracking-widest"
              >
            </label>
            <ErrorBanner :message="error" />
            <button
              type="submit"
              :disabled="busy || code.length !== 6"
              class="w-full rounded bg-slate-900 px-3 py-2 text-white disabled:opacity-50"
            >
              Confirm
            </button>
          </form>
        </template>
      </template>
      <template v-else>
        <h1 class="text-xl font-semibold">
          Save your recovery codes
        </h1>
        <p class="mt-1 text-sm text-slate-600">
          Each code signs you in once if you lose your phone. This is the only time they are shown.
        </p>
        <ul class="mt-3 grid grid-cols-2 gap-1 rounded bg-slate-100 p-3 font-mono text-sm">
          <li
            v-for="c in codes"
            :key="c"
          >
            {{ c }}
          </li>
        </ul>
        <label class="mt-3 flex items-center gap-2 text-sm">
          <input
            v-model="saved"
            type="checkbox"
          > I have saved these codes
        </label>
        <button
          type="button"
          :disabled="!saved"
          class="mt-3 w-full rounded bg-slate-900 px-3 py-2 text-white disabled:opacity-50"
          @click="finish"
        >
          Continue to the dashboard
        </button>
      </template>
    </div>
  </main>
</template>
