import { useQuery } from "@tanstack/vue-query";
import { api } from "./api";
import { can, type Permission } from "../shared/can";
import type { Me } from "./types";

export const meQuery = { queryKey: ["me"], queryFn: () => api.get<Me>("/me") };

export function useMe() {
  const query = useQuery(meQuery);
  const allowed = (p: Permission) => !!query.data.value && can(query.data.value.permissions, p);
  return { ...query, allowed };
}
