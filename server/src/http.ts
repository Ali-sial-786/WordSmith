/**
 * JSON responses and errors. Every error body is `{error: code, message?}`
 * (docs/TECH.md §4), so the app can switch on `error`.
 */

/** A failure that becomes a JSON error response. Throw it from any handler. */
export class ApiError extends Error {
  /**
   * @param status HTTP status
   * @param code   machine-readable code, sent as `error`
   * @param detail optional human-readable detail, sent as `message`
   */
  constructor(
    readonly status: number,
    readonly code: string,
    readonly detail?: string,
  ) {
    super(detail ?? code);
    this.name = "ApiError";
  }
}

export function json(body: unknown, status = 200, headers?: HeadersInit): Response {
  return Response.json(body, { status, headers });
}

export function errorResponse(status: number, code: string, message?: string, headers?: HeadersInit): Response {
  return json(message === undefined ? { error: code } : { error: code, message }, status, headers);
}

/** Request bodies larger than this are refused (sync has its own, larger cap). */
export const DEFAULT_MAX_BODY_BYTES = 16 * 1024;

/**
 * Reads a JSON request body of at most `maxBytes` bytes.
 * Throws 413 `payload_too_large` or 400 `invalid_json`.
 */
export async function readJson(request: Request, maxBytes = DEFAULT_MAX_BODY_BYTES): Promise<unknown> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > maxBytes) throw new ApiError(413, "payload_too_large");
  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > maxBytes) throw new ApiError(413, "payload_too_large");
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new ApiError(400, "invalid_json");
  }
}

/** Reads a JSON body that must be an object. */
export async function readJsonObject(request: Request, maxBytes?: number): Promise<Record<string, unknown>> {
  const body = await readJson(request, maxBytes);
  if (!isRecord(body)) throw new ApiError(400, "invalid_body", "Expected a JSON object");
  return body;
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
