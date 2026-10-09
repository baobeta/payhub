<script setup lang="ts">
import { ref } from "vue";
import { api } from "../api";
import { useMe } from "../useMe";
import { ApiFailure } from "../../shared/http";
import ErrorBanner from "../../shared/components/ErrorBanner.vue";

const { data: me } = useMe();
const current = ref("");
const next = ref("");
const message = ref<string | null>(null);
const error = ref<string | null>(null);
const codes = ref<string[] | null>(null);

async function act(fn: () => Promise<void>) {
  error.value = null;
  message.value = null;
  try {
    await fn();
  } catch (e) {
    error.value = e instanceof ApiFailure ? e.message : "Something went wrong. Try again.";
  }
}

const changePassword = () =>
  act(async () => {
    await api.patch("/me/password", { current_password: current.value, new_password: next.value });
    current.value = "";
    next.value = "";
    message.value = "Password changed. Your other sessions were signed out.";
  });

const regenerate = () =>
  act(async () => {
    codes.value = (await api.post<{ recovery_codes: string[] }>("/me/recovery_codes")).recovery_codes;
  });
</script>

<template>
  <div
    v-if="me"
    class="max-w-md space-y-8"
  >
    <h1 class="text-2xl font-semibold">
      Profile
    </h1>
    <p class="text-sm text-slate-600">
      {{ me.user.email }} · {{ me.user.role }}
    </p>
    <form
      class="space-y-3"
      @submit.prevent="changePassword"
    >
      <h2 class="text-lg font-semibold">
        Change password
      </h2>
      <label class="block text-sm font-medium">Current password
        <input
          v-model="current"
          type="password"
          autocomplete="current-password"
          class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
        >
      </label>
      <label class="block text-sm font-medium">New password (at least 12 characters)
        <input
          v-model="next"
          type="password"
          minlength="12"
          autocomplete="new-password"
          class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
        >
      </label>
      <button
        type="submit"
        :disabled="next.length < 12 || !current"
        class="rounded bg-slate-900 px-3 py-1.5 text-sm text-white disabled:opacity-50"
      >
        Change password
      </button>
    </form>
    <section class="space-y-3">
      <h2 class="text-lg font-semibold">
        Recovery codes
      </h2>
      <p class="text-sm text-slate-600">
        New codes replace every old one.
      </p>
      <button
        type="button"
        class="rounded border border-slate-300 bg-white px-3 py-1.5 text-sm"
        @click="regenerate"
      >
        Generate new codes
      </button>
      <ul
        v-if="codes"
        class="grid grid-cols-2 gap-1 rounded bg-slate-100 p-3 font-mono text-sm"
      >
        <li
          v-for="c in codes"
          :key="c"
        >
          {{ c }}
        </li>
      </ul>
    </section>
    <p
      v-if="message"
      class="text-sm text-emerald-700"
    >
      {{ message }}
    </p>
    <ErrorBanner :message="error" />
  </div>
</template>
