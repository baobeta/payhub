// One timeline shape for both areas: merchant and operator payment details.
export type TimelineEntry = {
  kind: "transition" | "capture" | "refund" | "ledger_transfer" | "event";
  at: string;
  [key: string]: unknown;
};
