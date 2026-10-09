import js from "@eslint/js";
import tseslint from "typescript-eslint";
import vue from "eslint-plugin-vue";

export default tseslint.config(
  { ignores: ["public/**", "node_modules/**", "tmp/**"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  ...vue.configs["flat/recommended"],
  { files: ["**/*.vue"], languageOptions: { parserOptions: { parser: tseslint.parser } } },
  // TypeScript already reports undefined names, and knows browser globals.
  { files: ["**/*.ts", "**/*.vue"], rules: { "no-undef": "off" } },
  // Route pages are named by their route (Team, Profile); the rule is for reusable components.
  { files: ["app/frontend/*/pages/**/*.vue"], rules: { "vue/multi-word-component-names": "off" } },
);
