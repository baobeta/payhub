// One client per area. The server enforces everything; this only carries
// the CSRF token and the idempotency key, and routes 401s to the right place.
export class ApiFailure extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public retriable = false,
    public details: Record<string, unknown> = {},
  ) {
    super(message);
  }
}

export type RequestOptions = { idempotencyKey?: string; poll?: boolean };
type StepUpHandler = () => Promise<boolean>;

function csrfToken(): string {
  return document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? "";
}

export function createClient(base: string) {
  let stepUp: StepUpHandler = async () => false;
  let unauthenticated: () => void = () => {};

  async function request<T>(method: string, path: string, body?: unknown, opts: RequestOptions = {}, retried = false): Promise<T> {
    const headers: Record<string, string> = { Accept: "application/json" };
    if (method !== "GET") {
      headers["Content-Type"] = "application/json";
      headers["X-CSRF-Token"] = csrfToken();
    }
    if (opts.idempotencyKey) headers["Idempotency-Key"] = opts.idempotencyKey;
    if (opts.poll) headers["X-Poll"] = "1";

    const res = await fetch(`${base}${path}`, {
      method,
      headers,
      credentials: "same-origin",
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (res.status === 204) return undefined as T;

    const text = await res.text();
    const parsed = text ? JSON.parse(text) : {};
    if (res.ok) return parsed as T;

    const err = parsed.error ?? {};
    const failure = new ApiFailure(res.status, err.code ?? "error", err.message ?? res.statusText, !!err.retriable, err.details ?? {});
    if (res.status === 401 && failure.code === "step_up_required") {
      if (!retried && (await stepUp())) return request<T>(method, path, body, opts, true);
    } else if (res.status === 401) {
      unauthenticated();
    }
    throw failure;
  }

  return {
    get: <T>(path: string, opts?: RequestOptions) => request<T>("GET", path, undefined, opts),
    post: <T>(path: string, body?: unknown, opts?: RequestOptions) => request<T>("POST", path, body, opts),
    put: <T>(path: string, body?: unknown, opts?: RequestOptions) => request<T>("PUT", path, body, opts),
    patch: <T>(path: string, body?: unknown, opts?: RequestOptions) => request<T>("PATCH", path, body, opts),
    delete: <T>(path: string, opts?: RequestOptions) => request<T>("DELETE", path, undefined, opts),
    onStepUp(handler: StepUpHandler) {
      stepUp = handler;
    },
    onUnauthenticated(handler: () => void) {
      unauthenticated = handler;
    },
  };
}

export type ApiClient = ReturnType<typeof createClient>;
