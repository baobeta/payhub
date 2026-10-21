<script setup lang="ts">
import { computed } from "vue";
import { useRoute } from "vue-router";
import SignInPage from "../../shared/pages/SignIn.vue";
import { api } from "../api";

// The link in the authenticator-reset email (DECISIONS #25).
const route = useRoute();
const token = computed(() => (typeof route.query.token === "string" ? route.query.token : ""));
</script>

<template>
  <SignInPage
    :client="api"
    :reset-token="token"
  />
</template>
