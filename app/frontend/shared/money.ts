import { EXPONENT } from "./currencies";

// Minor units ↔ display. Exponents come from app/lib/currency.rb via the
// generated currencies.ts, so both sides agree on what "12.34" means.
export function exponentOf(currency: string): number {
  const exp = EXPONENT[currency];
  if (exp === undefined) throw new Error(`unsupported currency ${currency}`);
  return exp;
}

export function formatMoney(minor: number, currency: string): string {
  const exp = exponentOf(currency);
  return new Intl.NumberFormat("en", {
    style: "currency",
    currency,
    minimumFractionDigits: exp,
    maximumFractionDigits: exp,
  }).format(minor / 10 ** exp);
}

// NaN for anything that is not a plain amount with at most the currency's
// decimals: "10.555" USD is a typo, not 10.56.
export function toMinor(major: string, currency: string): number {
  const exp = exponentOf(currency);
  const pattern = exp === 0 ? /^\d+$/ : new RegExp(`^\\d+(\\.\\d{1,${exp}})?$`);
  if (!pattern.test(major.trim())) return NaN;
  return Math.round(Number(major) * 10 ** exp);
}

export function minorToInput(minor: number, currency: string): string {
  const exp = exponentOf(currency);
  return (minor / 10 ** exp).toFixed(exp);
}
