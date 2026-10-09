import { defineConfig } from "@playwright/test";

// Runs the real app in the test environment on its own port, against its own
// database (payhub_e2e, rebuilt every run), with the e2e seed and a
// production-style Vite build.
const env = "RAILS_ENV=test TEST_DATABASE=payhub_e2e";
export default defineConfig({
  testDir: "e2e",
  timeout: 120_000,
  retries: 0,
  use: { baseURL: "http://localhost:3210", trace: "retain-on-failure" },
  webServer: {
    command: [
      `${env} bin/rails db:drop db:create db:schema:load`,
      `${env} bin/rails e2e:seed`,
      `${env} bin/vite build --mode=test`,
      `${env} bin/rails s -p 3210 -P tmp/pids/e2e.pid`,
    ].join(" && "),
    url: "http://localhost:3210/healthz",
    timeout: 180_000,
    reuseExistingServer: false,
  },
});
