import { reactive } from "vue";

// The step-up dialog is opened by the HTTP client (on 401 step_up_required)
// and answers with a promise: true once confirmed, false if cancelled.
export const stepUpState = reactive<{ open: boolean; resolve: ((ok: boolean) => void) | null }>({
  open: false,
  resolve: null,
});

export function requestStepUp(): Promise<boolean> {
  return new Promise((resolve) => {
    stepUpState.resolve = resolve;
    stepUpState.open = true;
  });
}

export function finishStepUp(ok: boolean) {
  stepUpState.resolve?.(ok);
  stepUpState.resolve = null;
  stepUpState.open = false;
}
