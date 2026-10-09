<script setup lang="ts">
import { DialogClose, DialogContent, DialogDescription, DialogOverlay, DialogPortal, DialogRoot, DialogTitle } from "reka-ui";

defineProps<{ open: boolean; title: string; description?: string }>();
const emit = defineEmits<{ "update:open": [boolean] }>();
</script>

<template>
  <DialogRoot
    :open="open"
    @update:open="emit('update:open', $event)"
  >
    <DialogPortal>
      <DialogOverlay class="fixed inset-0 z-40 bg-slate-900/40" />
      <DialogContent class="fixed left-1/2 top-1/2 z-50 w-[min(28rem,calc(100vw-2rem))] -translate-x-1/2 -translate-y-1/2 rounded-lg bg-white p-6 shadow-xl">
        <DialogTitle class="text-lg font-semibold text-slate-900">
          {{ title }}
        </DialogTitle>
        <DialogDescription
          v-if="description"
          class="mt-1 text-sm text-slate-600"
        >
          {{ description }}
        </DialogDescription>
        <div class="mt-4">
          <slot />
        </div>
        <DialogClose
          class="absolute right-3 top-3 rounded p-1 text-slate-500 hover:bg-slate-100"
          aria-label="Close"
        >
          ✕
        </DialogClose>
      </DialogContent>
    </DialogPortal>
  </DialogRoot>
</template>
