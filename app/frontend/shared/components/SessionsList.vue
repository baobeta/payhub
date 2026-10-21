<script setup lang="ts">
import { ref } from "vue";
import { useQuery, useQueryClient } from "@tanstack/vue-query";
import { ApiFailure, type ApiClient } from "../http";
import ErrorBanner from "./ErrorBanner.vue";

// M7: your signed-in browsers, as on GitHub and Stripe. Ending one needs a
// fresh code; the client opens the step-up dialog on 401 step_up_required.
// The current session is ended by signing out, so it has no button here.
type SessionRow = {
  id: string;
  browser: string;
  os: string;
  ip: string | null;
  created_at: string;
  last_active_at: string;
  current: boolean;
};

const props = defineProps<{ client: ApiClient }>();
const queryClient = useQueryClient();
const sessions = useQuery({
  queryKey: ["sessions"],
  queryFn: () => props.client.get<{ data: SessionRow[] }>("/sessions"),
});
const error = ref<string | null>(null);
const message = ref<string | null>(null);

async function act(fn: () => Promise<string>) {
  error.value = null;
  message.value = null;
  try {
    message.value = await fn();
  } catch (e) {
    error.value = e instanceof ApiFailure ? e.message : "Something went wrong. Try again.";
  } finally {
    queryClient.invalidateQueries({ queryKey: ["sessions"] });
  }
}

const revoke = (s: SessionRow) =>
  act(async () => {
    await props.client.delete(`/sessions/${s.id}`);
    return `Signed out ${s.browser} on ${s.os}.`;
  });

const revokeOthers = () =>
  act(async () => {
    const { revoked } = await props.client.post<{ revoked: number }>("/sessions/revoke_others");
    return revoked === 1 ? "Signed out 1 other session." : `Signed out ${revoked} other sessions.`;
  });

const when = (iso: string) => new Date(iso).toLocaleString();
</script>

<template>
  <section class="space-y-3">
    <h2 class="text-lg font-semibold">
      Sessions
    </h2>
    <p class="text-sm text-slate-600">
      Browsers signed in to your account. Sign out any you don't recognise.
    </p>
    <ul class="divide-y divide-slate-100 rounded bg-white text-sm shadow-sm">
      <li
        v-for="s in sessions.data.value?.data ?? []"
        :key="s.id"
        class="flex items-center gap-3 p-3"
        data-testid="session-row"
      >
        <div>
          <span class="font-medium">{{ s.browser }} on {{ s.os }}</span>
          <span
            v-if="s.current"
            class="ml-2 rounded bg-emerald-100 px-1.5 py-0.5 text-xs text-emerald-800"
          >This browser</span>
          <span class="block text-xs text-slate-500">
            {{ s.ip ?? "unknown IP" }} · signed in {{ when(s.created_at) }} · last active {{ when(s.last_active_at) }}
          </span>
        </div>
        <button
          v-if="!s.current"
          type="button"
          class="ml-auto text-red-700 underline"
          :aria-label="`Sign out ${s.browser} on ${s.os}`"
          @click="revoke(s)"
        >
          Sign out
        </button>
      </li>
    </ul>
    <button
      v-if="(sessions.data.value?.data ?? []).some((s) => !s.current)"
      type="button"
      class="rounded border border-slate-300 bg-white px-3 py-1.5 text-sm"
      data-testid="revoke-others"
      @click="revokeOthers"
    >
      Sign out all other sessions
    </button>
    <p
      v-if="message"
      class="text-sm text-emerald-700"
    >
      {{ message }}
    </p>
    <ErrorBanner :message="error" />
  </section>
</template>
