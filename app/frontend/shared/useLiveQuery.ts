import { useQuery, type QueryKey } from "@tanstack/vue-query";
import { computed, type MaybeRef, unref } from "vue";

// Polling in one place (design §1): the interval comes from the data, and
// TanStack pauses it while the tab is hidden. Action Cable can replace this
// composable later without touching a page.
export function useLiveQuery<T>(
  key: MaybeRef<QueryKey>,
  fetcher: (poll: boolean) => Promise<T>,
  intervalFor: (data: T) => number | false,
) {
  let first = true;
  return useQuery({
    queryKey: computed(() => unref(key)),
    queryFn: () => {
      const poll = !first;
      first = false;
      return fetcher(poll);
    },
    refetchInterval: (query) => (query.state.data ? intervalFor(query.state.data as T) : false),
    refetchIntervalInBackground: false,
  });
}
