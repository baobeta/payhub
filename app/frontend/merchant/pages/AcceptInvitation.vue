<script setup lang="ts">
import { computed, ref } from "vue";
import { useQuery } from "@tanstack/vue-query";
import { useRoute, useRouter } from "vue-router";
import { api } from "../api";
import { ApiFailure } from "../../shared/http";
import ErrorBanner from "../../shared/components/ErrorBanner.vue";

const route = useRoute();
const router = useRouter();
const token = computed(() => String(route.params.token));
const invitation = useQuery({
  queryKey: ["invitation", token],
  queryFn: () => api.get<{ email: string; role: string; merchant_name: string }>(`/invitations/${token.value}`),
});

const name = ref("");
const password = ref("");
const error = ref<string | null>(null);
const busy = ref(false);

async function accept() {
  busy.value = true;
  error.value = null;
  try {
    await api.post(`/invitations/${token.value}/accept`, { name: name.value, password: password.value });
    router.push({ name: "enrol" });
  } catch (e) {
    error.value = e instanceof ApiFailure ? e.message : "Something went wrong. Try again.";
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <main class="flex min-h-screen items-center justify-center bg-slate-50 p-4">
    <div class="w-full max-w-sm rounded-lg bg-white p-6 shadow">
      <p
        v-if="invitation.isError.value"
        role="alert"
      >
        This invitation has expired or was already used. Ask your account admin to invite you again.
      </p>
      <template v-else-if="invitation.data.value">
        <h1 class="text-xl font-semibold">
          Join {{ invitation.data.value.merchant_name }}
        </h1>
        <p class="mt-1 text-sm text-slate-600">
          {{ invitation.data.value.email }} · {{ invitation.data.value.role }}
        </p>
        <form
          class="mt-4 space-y-3"
          @submit.prevent="accept"
        >
          <label class="block text-sm font-medium text-slate-700">
            Your name
            <input
              v-model="name"
              required
              autocomplete="name"
              class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
            >
          </label>
          <label class="block text-sm font-medium text-slate-700">
            Password (at least 12 characters)
            <input
              v-model="password"
              type="password"
              minlength="12"
              required
              autocomplete="new-password"
              class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
            >
          </label>
          <ErrorBanner :message="error" />
          <button
            type="submit"
            :disabled="busy || password.length < 12"
            class="w-full rounded bg-slate-900 px-3 py-2 text-white disabled:opacity-50"
          >
            Continue
          </button>
        </form>
      </template>
    </div>
  </main>
</template>
