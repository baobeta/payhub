import { expect, test, type Page } from "@playwright/test";
import { TOTP } from "otpauth";

const totp = new TOTP({ secret: "JBSWY3DPEHPK3PXP" });

// A TOTP code works once (replay guard). Before a second code, wait for the
// next 30-second step.
async function nextStep(page: Page) {
  await page.waitForTimeout(30_000 - (Date.now() % 30_000) + 750);
}

test("support signs in with 2FA and refunds a captured payment", async ({ page }) => {
  await page.goto("/dashboard/payments");
  await expect(page).toHaveURL(/\/dashboard\/sign-in/);

  await page.getByLabel("Email").fill("support@e2e.test");
  await page.getByLabel("Password").fill("e2e password 1234");
  await page.getByRole("button", { name: "Continue" }).click();
  await page.getByLabel("Authenticator code").fill(totp.generate());
  await page.getByRole("button", { name: "Sign in" }).click();

  await expect(page).toHaveURL(/\/dashboard\/payments$/);
  await page.getByRole("link", { name: /captured/i }).first().click();

  await page.getByRole("button", { name: "Refund" }).click();
  await page.getByTestId("refund-reason").selectOption("requested_by_customer");
  await page.getByTestId("refund-submit").click();

  // Refund is sensitive: the server asks for step-up, the client opens the
  // dialog, then retries the same request with the same idempotency key.
  await expect(page.getByRole("heading", { name: "Confirm it's you" })).toBeVisible();
  await nextStep(page);
  await page.getByRole("dialog", { name: "Confirm it's you" }).getByLabel("Authenticator code").fill(totp.generate());
  await page.getByRole("button", { name: "Confirm" }).click();

  await expect(page.getByText(/Refund of €25\.00: pending/)).toBeVisible();
});

test("a signed-out deep link lands on sign-in, not on data", async ({ page }) => {
  await page.goto("/dashboard/payments/00000000-0000-0000-0000-000000000000");
  await expect(page).toHaveURL(/sign-in/);
});
