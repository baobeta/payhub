import type { MerchantPermission, OperatorPermission } from "./permissions";

export type Permission = MerchantPermission | OperatorPermission;

// For hiding UI only. The server enforces every request (design §3).
export function can(granted: readonly Permission[], permission: Permission): boolean {
  return granted.includes(permission);
}
