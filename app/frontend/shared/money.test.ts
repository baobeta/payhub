import { describe, expect, it } from "vitest";
import { exponentOf, formatMoney, minorToInput, toMinor } from "./money";

describe("money", () => {
  it("formats minor units with the server's exponents", () => {
    expect(formatMoney(2500, "EUR")).toBe("€25.00");
    expect(formatMoney(500000, "VND")).toBe("₫500,000");
    expect(formatMoney(1234, "IDR")).toMatch(/^IDR\s12\.34$/u); // Intl uses a no-break space
  });

  it("parses a typed amount back to minor units", () => {
    expect(toMinor("12.34", "EUR")).toBe(1234);
    expect(toMinor("500000", "VND")).toBe(500000);
    expect(toMinor("abc", "EUR")).toBeNaN();
    expect(toMinor("10.555", "USD")).toBeNaN(); // more decimals than the currency has
    expect(toMinor("100.4", "VND")).toBeNaN();
  });

  it("round-trips a minor amount through the input format", () => {
    expect(minorToInput(1234, "EUR")).toBe("12.34");
    expect(exponentOf("VND")).toBe(0);
  });
});
