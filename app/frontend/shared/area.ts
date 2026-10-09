import type { ComputedRef, InjectionKey } from "vue";
import type { ApiClient } from "./http";
import type { Permission } from "./can";

// A read page belongs to an "area": the merchant console, or an operator
// viewing a merchant read-only. The area supplies the API client and the
// viewer's identity, so the same page component serves both.
export type AreaMe = {
  user: { id: string; email: string; name: string | null; role: string };
  merchant: { id: string; name: string };
  livemode: boolean;
  permissions: Permission[];
  impersonating?: boolean;
};

export const AREA_CLIENT: InjectionKey<ApiClient> = Symbol("areaClient");
export const AREA_ME: InjectionKey<ComputedRef<AreaMe | null>> = Symbol("areaMe");
// Path prefix for links inside the area. Empty in the merchant console; inside
// the operator console it is `/as/:merchantId` so links stay in the read-only view.
export const AREA_BASE: InjectionKey<string> = Symbol("areaBase");
