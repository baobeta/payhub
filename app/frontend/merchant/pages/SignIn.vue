<script setup lang="ts">
import { ref } from "vue";
import { useRoute, useRouter } from "vue-router";
import { useQueryClient } from "@tanstack/vue-query";
import { api } from "../api";
import { ApiFailure } from "../../shared/http";
import ErrorBanner from "../../shared/components/ErrorBanner.vue";
import type { Me } from "../types";

const route = useRoute();
const router = useRouter();
const queryClient = useQueryClient();

const step = ref<"password" | "code">("password");
const useRecovery = ref(false);
const email = ref("");
const password = ref("");
const code = ref("");
const error = ref<string | null>(null);
const busy = ref(false);

function explain(e: unknown): string {
  if (!(e instanceof ApiFailure)) return "Something went wrong. Try again.";
  if (e.status === 423) return `Too many attempts. Try again after ${new Date(String((e.details.locked_until as string[])?.[0])).toLocaleTimeString()}.`;
  return e.message; // never says whether the email exists
}

async function submitPassword() {
  busy.value = true;
  error.value = null;
  try {
    await api.post("/session", { email: email.value, password: password.value });
    step.value = "code";
  } catch (e) {
    error.value = explain(e);
  } finally {
    busy.value = false;
  }
}

async function submitCode() {
  busy.value = true;
  error.value = null;
  try {
    const me = await api.post<Me>(useRecovery.value ? "/session/recovery" : "/session/otp", { code: code.value });
    queryClient.setQueryData(["me"], me);
    const next = typeof route.query.next === "string" && route.query.next.startsWith("/") ? route.query.next : "/";
    router.push(next);
  } catch (e) {
    error.value = explain(e);
    if (e instanceof ApiFailure && e.code === "password_step_required") step.value = "password";
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <main class="flex min-h-screen items-center justify-center bg-slate-50 p-4">
    <div class="w-full max-w-sm rounded-lg bg-white p-6 shadow">
      <h1 class="text-xl font-semibold">
        Sign in to PayHub
      </h1>
      <form
        v-if="step === 'password'"
        class="mt-4 space-y-3"
        @submit.prevent="submitPassword"
      >
        <label class="block text-sm font-medium text-slate-700">
          Email
          <input
            v-model="email"
            type="email"
            autocomplete="username"
            required
            class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          >
        </label>
        <label class="block text-sm font-medium text-slate-700">
          Password
          <input
            v-model="password"
            type="password"
            autocomplete="current-password"
            required
            class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          >
        </label>
        <ErrorBanner :message="error" />
        <button
          type="submit"
          :disabled="busy"
          class="w-full rounded bg-slate-900 px-3 py-2 text-white disabled:opacity-50"
        >
          Continue
        </button>
      </form>
      <form
        v-else
        class="mt-4 space-y-3"
        @submit.prevent="submitCode"
      >
        <label
          v-if="!useRecovery"
          class="block text-sm font-medium text-slate-700"
        >
          Authenticator code
          <input
            v-model="code"
            inputmode="numeric"
            autocomplete="one-time-code"
            maxlength="6"
            class="mt-1 w-full rounded border border-slate-300 px-3 py-2 tracking-widest"
          >
        </label>
        <label
          v-else
          class="block text-sm font-medium text-slate-700"
        >
          Recovery code
          <input
            v-model="code"
            autocomplete="off"
            class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          >
        </label>
        <ErrorBanner :message="error" />
        <button
          type="submit"
          :disabled="busy || code === ''"
          class="w-full rounded bg-slate-900 px-3 py-2 text-white disabled:opacity-50"
        >
          Sign in
        </button>
        <button
          type="button"
          class="text-sm underline"
          @click="useRecovery = !useRecovery; code = ''"
        >
          {{ useRecovery ? "Use your authenticator app" : "Use a recovery code" }}
        </button>
      </form>
    </div>
  </main>
</template>
