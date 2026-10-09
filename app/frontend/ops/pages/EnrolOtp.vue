<script setup lang="ts">
import EnrolOtpPage from "../../shared/pages/EnrolOtp.vue";
import { api } from "../api";
</script>

<template>
  <EnrolOtpPage :client="api" />
</template>
