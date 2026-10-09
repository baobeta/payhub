import { createApp } from "vue";
import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import "../styles.css";
import App from "../ops/App.vue";
import { router } from "../ops/router";
import { api } from "../ops/api";
import { meQuery } from "../ops/useMe";
import { requestStepUp } from "../shared/stepUp";
import { can } from "../shared/can";

const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: 5_000 } } });

api.onStepUp(requestStepUp);
api.onUnauthenticated(() => {
  queryClient.clear();
  const next = router.currentRoute.value.fullPath;
  if (!router.currentRoute.value.meta.public) router.push({ name: "sign-in", query: { next } });
});

// Signed-in pages need `me`; a page the role cannot use sends you to the queue.
// The server still refuses every request the role lacks.
router.beforeEach(async (to) => {
  if (to.meta.public) return true;
  try {
    const me = await queryClient.fetchQuery(meQuery);
    if (to.meta.permission && !can(me.permissions, to.meta.permission)) {
      return to.name === "queue" ? true : { name: "queue" };
    }
    return true;
  } catch {
    return { name: "sign-in", query: { next: to.fullPath } };
  }
});

createApp(App).use(router).use(VueQueryPlugin, { queryClient }).mount("#app");
