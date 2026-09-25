<script setup lang="ts">
import { ref } from "vue";
import { useQuery, useQueryClient } from "@tanstack/vue-query";
import { api } from "../api";
import { useMe } from "../useMe";
import { ApiFailure } from "../../shared/http";
import BaseModal from "../../shared/components/BaseModal.vue";
import ErrorBanner from "../../shared/components/ErrorBanner.vue";
import StatusBadge from "../../shared/components/StatusBadge.vue";
import ConfirmDialog from "../components/ConfirmDialog.vue";

type Member = { id: string; email: string; name: string | null; role: string; status: string; invitation_expires_at: string | null };

const ROLES = ["admin", "developer", "support", "viewer"]; // owner only through transfer
const { data: me, allowed } = useMe();
const queryClient = useQueryClient();
const members = useQuery({ queryKey: ["members"], queryFn: () => api.get<{ data: Member[] }>("/members") });

const error = ref<string | null>(null);
const inviteOpen = ref(false);
const inviteEmail = ref("");
const inviteRole = ref("viewer");
const removing = ref<Member | null>(null);
const transferTo = ref<Member | null>(null);

async function act(fn: () => Promise<unknown>) {
  error.value = null;
  try {
    await fn();
    inviteOpen.value = false;
    removing.value = null;
    transferTo.value = null;
  } catch (e) {
    error.value = e instanceof ApiFailure ? e.message : "Something went wrong. Try again.";
  } finally {
    queryClient.invalidateQueries({ queryKey: ["members"] });
    queryClient.invalidateQueries({ queryKey: ["me"] }); // a role change may be our own view's
  }
}

const editable = (m: Member) => allowed("team.manage") && m.status === "active" && m.role !== "owner" && m.id !== me.value?.user.id;
</script>

<template>
  <div class="space-y-4">
    <div class="flex items-center">
      <h1 class="text-2xl font-semibold">
        Team
      </h1>
      <button
        v-if="allowed('team.manage')"
        type="button"
        class="ml-auto rounded bg-slate-900 px-3 py-1.5 text-sm text-white"
        @click="inviteOpen = true; inviteEmail = ''; inviteRole = 'viewer'"
      >
        Invite
      </button>
    </div>
    <ErrorBanner :message="error" />
    <table class="w-full rounded bg-white text-sm shadow-sm">
      <thead class="text-left text-slate-500">
        <tr>
          <th class="p-2">
            Person
          </th><th class="p-2">
            Role
          </th><th class="p-2">
            Status
          </th><th class="p-2" />
        </tr>
      </thead>
      <tbody>
        <tr
          v-for="m in members.data.value?.data ?? []"
          :key="m.id"
          class="border-t border-slate-100"
        >
          <td class="p-2">
            {{ m.name ?? "—" }}<span class="block text-xs text-slate-500">{{ m.email }}</span>
          </td>
          <td class="p-2">
            <select
              v-if="editable(m)"
              :value="m.role"
              :aria-label="`Role for ${m.email}`"
              class="rounded border border-slate-300 px-2 py-1"
              @change="act(() => api.patch(`/members/${m.id}`, { role: ($event.target as HTMLSelectElement).value }))"
            >
              <option
                v-for="r in ROLES"
                :key="r"
                :value="r"
              >
                {{ r }}
              </option>
            </select>
            <span v-else>{{ m.role }}</span>
          </td>
          <td class="p-2">
            <StatusBadge :status="m.status" />
          </td>
          <td class="p-2 text-right">
            <button
              v-if="allowed('ownership.transfer') && m.status === 'active' && m.role !== 'owner'"
              type="button"
              class="mr-2 underline"
              @click="transferTo = m"
            >
              Make owner
            </button>
            <button
              v-if="editable(m) || (allowed('team.manage') && m.status === 'invited')"
              type="button"
              class="text-red-700 underline"
              @click="removing = m"
            >
              Remove
            </button>
          </td>
        </tr>
      </tbody>
    </table>
    <BaseModal
      v-model:open="inviteOpen"
      title="Invite a teammate"
      description="They get an email link, valid for 10 days, to set a password and an authenticator app."
    >
      <form
        class="space-y-3"
        @submit.prevent="act(() => api.post('/invitations', { email: inviteEmail, role: inviteRole }))"
      >
        <label class="block text-sm font-medium">Email
          <input
            v-model="inviteEmail"
            type="email"
            required
            class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
          >
        </label>
        <label class="block text-sm font-medium">Role
          <select
            v-model="inviteRole"
            class="mt-1 w-full rounded border border-slate-300 px-3 py-2"
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
          class="w-full rounded bg-slate-900 px-3 py-2 text-white"
        >
          Send invitation
        </button>
      </form>
    </BaseModal>
    <ConfirmDialog
      :open="!!removing"
      title="Remove this teammate?"
      :description="`${removing?.email} loses access immediately and is signed out everywhere.`"
      confirm-label="Remove"
      :type-to-confirm="removing?.email"
      @update:open="(o: boolean) => { if (!o) removing = null }"
      @confirm="act(() => api.delete(`/members/${removing!.id}`))"
    />
    <ConfirmDialog
      :open="!!transferTo"
      title="Transfer ownership?"
      :description="`${transferTo?.email} becomes the owner and you become an admin. Only the new owner can transfer it back.`"
      confirm-label="Transfer ownership"
      :type-to-confirm="transferTo?.email"
      @update:open="(o: boolean) => { if (!o) transferTo = null }"
      @confirm="act(() => api.post('/ownership_transfer', { member_id: transferTo!.id }))"
    />
  </div>
</template>
