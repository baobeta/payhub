import { reactive } from "vue";

// The step-up dialog is opened by the HTTP client (on 401 step_up_required)
// and answers with a promise: true once confirmed, false if cancelled. Two
// requests that need it at once share one dialog and one answer.
export const stepUpState = reactive<{ open: boolean }>({ open: false });
let waiters: ((ok: boolean) => void)[] = [];

export function requestStepUp(): Promise<boolean> {
  return new Promise((resolve) => {
    waiters.push(resolve);
    stepUpState.open = true;
  });
}

export function finishStepUp(ok: boolean) {
  const answered = waiters;
  waiters = [];
  stepUpState.open = false;
  answered.forEach((resolve) => resolve(ok));
}
