/**
 * `GET /v1/apk/:version` (and `HEAD`): the Android app's APK for a version,
 * or `latest`, streamed from where releases are published (`APK_SOURCE_URL`).
 * `/v1/version` points the in-app updater here, so players download from the
 * game's own server and never see where the builds are kept.
 *
 * The body is passed through as it arrives, never buffered. `404 apk_not_found`
 * when that version isn't published (yet), which the app reads as "still on
 * its way"; `502 apk_unavailable` when the source couldn't be reached.
 *
 * Tests swap the network with {@link setApkFetcher}.
 */

import { ApiError } from "../http";
import type { RequestContext } from "./context";

const VERSION_RE = /^\d{1,4}\.\d{1,4}\.\d{1,4}$/;

let fetcher: typeof fetch = (input, init) => fetch(input, init);

/** For tests: where requests for APKs go instead of `fetch` (`null` restores it). */
export function setApkFetcher(fn: typeof fetch | null): void {
  fetcher = fn ?? ((input, init) => fetch(input, init));
}

export async function getApk(c: RequestContext): Promise<Response> {
  const source = c.env.APK_SOURCE_URL;
  const requested = c.params.version ?? "";
  const version = requested === "latest" ? c.env.LATEST_VERSION : requested;
  if (!source || !VERSION_RE.test(version)) throw new ApiError(404, "apk_not_found");

  const head = c.request.method === "HEAD";
  let upstream: Response;
  try {
    upstream = await fetcher(source.replaceAll("{version}", version), { method: head ? "HEAD" : "GET", redirect: "follow" });
  } catch (err) {
    console.error(`apk ${version}: the source couldn't be reached`, err);
    throw new ApiError(502, "apk_unavailable");
  }
  if (!upstream.ok) {
    await upstream.body?.cancel();
    if (upstream.status === 404) throw new ApiError(404, "apk_not_found");
    console.error(`apk ${version}: the source answered ${upstream.status}`);
    throw new ApiError(502, "apk_unavailable");
  }

  const headers = new Headers({
    "content-type": "application/vnd.android.package-archive",
    "content-disposition": `attachment; filename="wordsmith-${version}.apk"`,
    "cache-control": "no-store",
  });
  const length = Number(upstream.headers.get("content-length") ?? "");
  if (head || upstream.body === null) {
    if (length > 0) headers.set("content-length", String(length));
    await upstream.body?.cancel();
    return new Response(null, { status: 200, headers });
  }
  if (!(length > 0)) return new Response(upstream.body, { status: 200, headers });
  // A known length, so the app can show progress and check it got every byte.
  headers.set("content-length", String(length));
  const { readable, writable } = new FixedLengthStream(length);
  c.ctx.waitUntil(
    upstream.body.pipeTo(writable).catch((err: unknown) => {
      console.warn(`apk ${version}: the download stopped`, err);
    }),
  );
  return new Response(readable, { status: 200, headers });
}
