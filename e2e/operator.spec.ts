import { expect, test, type Page } from "@playwright/test";
import { TOTP } from "otpauth";

const opsTotp = new TOTP({ secret: "JBSWY3DPEHPK3PXP" });
const approverTotp = new TOTP({ secret: "KRSXG5CTMVRXEZLU" });

// A TOTP code works once (replay guard). Before a second code from the same
// user, wait for the next 30-second step.
async function nextStep(page: Page) {
  await page.waitForTimeout(30_000 - (Date.now() % 30_000) + 750);
}

async function signIn(page: Page, email: string, totp: TOTP) {
  await page.goto("/ops/");
  await expect(page).toHaveURL(/\/ops\/sign-in/);
  await page.getByLabel("Email").fill(email);
  await page.getByLabel("Password").fill("e2e password 1234");
  await page.getByRole("button", { name: "Continue" }).click();
  await page.getByLabel("Authenticator code").fill(totp.generate());
  await page.getByRole("button", { name: "Sign in" }).click();
}

test("an operator proposes a resolution and a second operator approves it", async ({ browser }) => {
  const opsContext = await browser.newContext();
  const ops = await opsContext.newPage();
  await signIn(ops, "ops@e2e.test", opsTotp);
  await expect(ops).toHaveURL(/\/ops\/$/);

  // 1. ops@ opens the queue, opens the stuck payment and proposes "failed".
  await ops.locator('section[aria-labelledby="unknown"] a').first().click();
  await expect(ops).toHaveURL(/\/ops\/payments\//);
  await ops.getByRole("button", { name: "Propose resolution" }).click();

  const propose = ops.getByRole("dialog", { name: "Propose a resolution" });
  await propose.getByLabel("Move to").selectOption("failed");
  await propose.getByLabel("Reason code").selectOption("psp_confirmed_outcome");
  await propose.getByLabel("What did you find?").fill("PSP log confirms the charge failed.");
  await propose.getByLabel("Case reference").fill("OPS-42");
  await propose.getByRole("button", { name: "Propose" }).click();

  // Creating a proposal is sensitive: the client steps up, then retries.
  await expect(ops.getByRole("dialog", { name: "Confirm it's you" })).toBeVisible();
  await nextStep(ops);
  await ops.getByRole("dialog", { name: "Confirm it's you" }).getByLabel("Authenticator code").fill(opsTotp.generate());
  await ops.getByRole("button", { name: "Confirm" }).click();

  await expect(ops.getByRole("link", { name: "OPS-42" })).toBeVisible();

  // 4. Negative: the proposer cannot approve their own proposal.
  await ops.getByRole("link", { name: "OPS-42" }).click();
  await expect(ops).toHaveURL(/\/ops\/proposals\//);
  await expect(ops.getByRole("button", { name: "Withdraw" })).toBeVisible();
  await expect(ops.getByRole("button", { name: "Approve" })).toHaveCount(0);

  // 2. A second operator, in a separate cookie jar, approves it.
  const approverContext = await browser.newContext();
  const approver = await approverContext.newPage();
  await signIn(approver, "approver@e2e.test", approverTotp);
  await approver.getByRole("link", { name: "Proposals" }).click();
  await expect(approver).toHaveURL(/\/ops\/proposals$/);
  await approver.getByRole("link", { name: "OPS-42" }).click();
  await expect(approver).toHaveURL(/\/ops\/proposals\//);
  await approver.getByLabel("Note (required to reject)").fill("Checked against the PSP call log.");
  await approver.getByRole("button", { name: "Approve" }).click();

  // Approving is sensitive too: step up, then the request is applied.
  await expect(approver.getByRole("dialog", { name: "Confirm it's you" })).toBeVisible();
  await nextStep(approver);
  await approver.getByRole("dialog", { name: "Confirm it's you" }).getByLabel("Authenticator code").fill(approverTotp.generate());
  await approver.getByRole("button", { name: "Confirm" }).click();
  await expect(approver.getByTestId("proposal-outcome")).toContainText("Applied");

  // 3. Back in the ops@ context the payment is now failed, moved by an operator.
  await ops.getByRole("link", { name: "open payment" }).click();
  await expect(ops).toHaveURL(/\/ops\/payments\//);
  await expect(ops.getByText(/unknown → failed \(operator\)/)).toBeVisible();

  await opsContext.close();
  await approverContext.close();
});
