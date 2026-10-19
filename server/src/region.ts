/**
 * Where a request comes from, as far as the rules need to know: Cloudflare
 * works out the country and province from the IP address (`request.cf`).
 * Nothing about it is stored.
 */

/**
 * Whether the request comes from Quebec, whose private-sector privacy law
 * (Law 25) needs a parent's consent below 14 and the most private settings
 * by default (shared/age.md).
 */
export function fromQuebec(request: Request): boolean {
  const cf = request.cf as { readonly country?: unknown; readonly regionCode?: unknown } | undefined;
  return cf?.country === "CA" && cf?.regionCode === "QC";
}
