<script setup lang="ts">
import AcceptInvitationPage from "../../shared/pages/AcceptInvitation.vue";
import { api } from "../api";
</script>

<template>
  <AcceptInvitationPage
    :client="api"
    fallback-name="PayHub Operations"
  />
</template>
