import { ref } from "vue";

// One key per user intent (DECISIONS #3): create when the modal opens,
// reuse on every retry of that submit, renew only when the modal reopens.
export function useIdempotencyKey() {
  const key = ref(crypto.randomUUID());
  return { key, renew: () => (key.value = crypto.randomUUID()) };
}
