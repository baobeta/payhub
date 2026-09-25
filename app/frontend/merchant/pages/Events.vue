<script setup lang="ts">
import { computed, ref } from "vue";
import { useInfiniteQuery, useQueryClient } from "@tanstack/vue-query";
import { api } from "../api";
import { useMe } from "../useMe";
import { ApiFailure } from "../../shared/http";
import ErrorBanner from "../../shared/components/ErrorBanner.vue";
import StatusBadge from "../../shared/components/StatusBadge.vue";
import type { List } from "../types";

type Attempt = { attempt: number; response_status: number | null; error: string | null; at: string };
type Event = {
  id: string; type: string; state: string; payment_id: string | null; attempts: number;
  next_attempt_at: string; last_error: string | null; created_at: string; delivery_attempts?: Attempt[];
};

const { allowed } = useMe();
const queryClient = useQueryClient();
const state = ref("");
const list = useInfiniteQuery({
  queryKey: computed(() => ["events", state.value]),
  initialPageParam: null as string | null,
  queryFn: ({ pageParam }) => {
    const p = new URLSearchParams({ ...(state.value ? { state: state.value } : {}), ...(pageParam ? { cursor: pageParam } : {}) });
    return api.get<List<Event>>(`/events?${p}`);
  },
  getNextPageParam: (last) => (last.has_more ? last.next_cursor : null),
});
const rows = computed(() => list.data.value?.pages.flatMap((p) => p.data) ?? []);

const open = ref<Record<string, Attempt[]>>({});
const error = ref<string | null>(null);

async function toggle(e: Event) {
  if (open.value[e.id]) {
    delete open.value[e.id];
    return;
  }
  const full = await api.get<Event>(`/events/${e.id}`);
  open.value[e.id] = full.delivery_attempts ?? [];
}

async function resend(e: Event) {
  error.value = null;
  try {
    await api.post(`/events/${e.id}/redeliver`);
  } catch (err) {
    error.value = err instanceof ApiFailure ? err.message : "Something went wrong. Try again.";
  } finally {
    queryClient.invalidateQueries({ queryKey: ["events"] });
  }
}
</script>

<template>
  <div class="space-y-4">
    <div class="flex items-center gap-3">
      <h1 class="text-2xl font-semibold">
        Events
      </h1>
      <label class="ml-auto text-sm">State
        <select
          v-model="state"
          class="ml-1 rounded border border-slate-300 px-2 py-1"
        >
          <option value="">Any</option>
          <option value="pending">pending</option>
          <option value="delivered">delivered</option>
          <option value="dead">dead</option>
        </select>
      </label>
    </div>
    <ErrorBanner :message="error" />
    <ul class="divide-y divide-slate-100 rounded bg-white text-sm shadow-sm">
      <li
        v-for="e in rows"
        :key="e.id"
        class="p-3"
      >
        <div class="flex items-center gap-3">
          <button
            type="button"
            class="font-mono underline"
            :aria-expanded="!!open[e.id]"
            @click="toggle(e)"
          >
            {{ e.type }}
          </button>
          <StatusBadge :status="e.state" />
          <span class="text-slate-500">{{ e.attempts }} attempt(s)</span>
          <RouterLink
            v-if="e.payment_id"
            :to="`/payments/${e.payment_id}`"
            class="underline"
          >
            payment
          </RouterLink>
          <button
            v-if="e.state === 'dead' && allowed('events.redeliver')"
            type="button"
            class="ml-auto rounded border border-slate-300 px-2 py-0.5"
            @click="resend(e)"
          >
            Resend
          </button>
        </div>
        <p
          v-if="e.last_error"
          class="mt-1 text-xs text-red-700"
        >
          {{ e.last_error }}
        </p>
        <ol
          v-if="open[e.id]"
          class="mt-2 space-y-1 text-xs"
        >
          <li
            v-for="a in open[e.id]"
            :key="a.attempt"
          >
            #{{ a.attempt }} · {{ new Date(a.at).toLocaleString() }} · HTTP {{ a.response_status ?? "—" }} {{ a.error ?? "" }}
          </li>
          <li v-if="open[e.id].length === 0">
            No delivery attempts yet.
          </li>
        </ol>
      </li>
    </ul>
    <button
      v-if="list.hasNextPage.value"
      type="button"
      class="rounded border border-slate-300 bg-white px-3 py-1 text-sm"
      @click="list.fetchNextPage()"
    >
      Load more
    </button>
  </div>
</template>
