// How often a payment page refetches, chosen from the payment's state.
// Returns false to stop polling.
export type PaymentState =
  | "pending"
  | "requires_action"
  | "authorized"
  | "unknown"
  | "captured"
  | "canceled"
  | "failed"
  | "part_refunded"
  | "refunded";

const TERMINAL: ReadonlySet<PaymentState> = new Set(["canceled", "failed", "refunded"]);

export function pollIntervalFor(state: PaymentState): number | false {
  if (TERMINAL.has(state)) return false;
  switch (state) {
    case "pending":
      return 2_000; // the worker usually answers within seconds
    case "requires_action":
      return 5_000; // waiting on a person; their approval arrives by webhook
    case "unknown":
      return 10_000; // the sweeper re-checks after 2 min, then backs off (DECISIONS #13)
    default:
      // authorized / captured / part_refunded move only when someone acts or a
      // capture/refund settles; our own actions refetch immediately anyway.
      return 15_000;
  }
}
