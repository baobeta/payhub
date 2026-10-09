<script setup lang="ts">
import SignInPage from "../../shared/pages/SignIn.vue";
import { api } from "../api";
</script>

<template>
  <SignInPage :client="api" />
</template>
