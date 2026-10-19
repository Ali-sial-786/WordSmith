/**
 * Where a request comes from, as far as the rules need to know: Cloudflare
 * works out the country and province from the IP address (`request.cf`).
 * Nothing about it is stored.
 */

import { ApiError } from "./http";

/**
 * The header an app sends once its player has said they don't live in
 * Quebec, for when the IP address puts them there by mistake (shared/region.md).
 */
export const NOT_IN_QUEBEC_HEADER = "X-Not-In-Quebec";

/** Whether the request comes from Quebec, where online play isn't offered (shared/region.md). */
export function fromQuebec(request: Request): boolean {
  const cf = request.cf as { readonly country?: unknown; readonly regionCode?: unknown } | undefined;
  return cf?.country === "CA" && cf?.regionCode === "QC";
}

/**
 * `403 quebec_not_offered` for a request from Quebec, unless its player has
 * said they live elsewhere.
 */
export function refuseQuebec(request: Request): void {
  if (fromQuebec(request) && request.headers.get(NOT_IN_QUEBEC_HEADER) !== "1") {
    throw new ApiError(403, "quebec_not_offered", "Online play isn't offered in Quebec");
  }
}
