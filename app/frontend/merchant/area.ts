import { computed, inject } from "vue";
import { api } from "./api";
import { useMe } from "./useMe";
import { can, type Permission } from "../shared/can";
import { AREA_BASE, AREA_CLIENT, AREA_ME, type AreaMe } from "../shared/area";

// Merchant read pages get their client and identity from the area they are
// mounted in. Inside the merchant console that is the merchant session; inside
// the operator console it is the read-only "view as merchant" session.
export function useArea() {
  const client = inject(AREA_CLIENT, null);
  const providedMe = inject(AREA_ME, null);
  const base = inject(AREA_BASE, "");

  if (client && providedMe) {
    const me = computed<AreaMe | null>(() => providedMe.value);
    const allowed = (p: Permission) => !!me.value && can(me.value.permissions, p);
    return { client, me, allowed, base };
  }

  const { data, allowed } = useMe();
  return { client: api, me: computed<AreaMe | null>(() => data.value ?? null), allowed, base };
}
