import { defineConfig } from "vite";
import RubyPlugin from "vite-plugin-ruby";
import vue from "@vitejs/plugin-vue";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [RubyPlugin(), vue(), tailwindcss()],
  // Under docker compose, Rails proxies /vite-dev to this server as "vite".
  server: { allowedHosts: ["vite"] },
});
