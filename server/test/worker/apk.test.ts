/**
 * `GET /v1/apk/:version` (src/routes/apk.ts): the in-app updater's download,
 * streamed from APK_SOURCE_URL, which setApkFetcher() answers here.
 */

import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it } from "vitest";
import worker from "../../src/index";
import { setApkFetcher } from "../../src/routes/apk";
import { versionInfo } from "../../src/version";
import { BASE } from "./helpers";

const APK_TYPE = "application/vnd.android.package-archive";

interface Asked {
  readonly url: string;
  readonly method: string;
}

/** Stands in for where releases are published: `files` by URL, anything else a 404. */
function fakeSource(files: Record<string, Uint8Array>, options: { status?: number; lengthless?: boolean; fail?: boolean } = {}) {
  const asked: Asked[] = [];
  const fetch: typeof globalThis.fetch = async (input, init) => {
    const req = new Request(input, init);
    asked.push({ url: req.url, method: req.method });
    if (options.fail) throw new TypeError("network down");
    if (options.status !== undefined) return new Response("nope", { status: options.status });
    const file = files[req.url];
    if (file === undefined) return new Response("Not Found", { status: 404 });
    if (options.lengthless) {
      const stream = new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(file);
          controller.close();
        },
      });
      return new Response(stream, { headers: { "content-type": "application/octet-stream" } });
    }
    return new Response(req.method === "HEAD" ? null : file, {
      headers: { "content-type": "application/octet-stream", "content-length": String(file.byteLength) },
    });
  };
  return { asked, fetch };
}

const sourceFor = (version: string) => env.APK_SOURCE_URL!.replaceAll("{version}", version);

function apk(size: number, seed = 7): Uint8Array {
  const bytes = new Uint8Array(size);
  for (let i = 0; i < size; i++) bytes[i] = (i * 31 + seed) & 0xff;
  return bytes;
}

async function download(path: string, method = "GET") {
  const ctx = createExecutionContext();
  const res = await worker.fetch(new Request(`${BASE}${path}`, { method }), env, ctx);
  const bytes = method === "HEAD" || res.status !== 200 ? null : new Uint8Array(await res.arrayBuffer());
  await waitOnExecutionContext(ctx);
  return { res, bytes };
}

afterEach(() => setApkFetcher(null));

describe("GET /v1/apk/:version", () => {
  it("streams that version's APK from the source, as an APK download", async () => {
    const file = apk(300_000);
    const source = fakeSource({ [sourceFor("0.6.0")]: file });
    setApkFetcher(source.fetch);
    const { res, bytes } = await download("/v1/apk/0.6.0");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe(APK_TYPE);
    expect(res.headers.get("content-disposition")).toBe('attachment; filename="wordsmith-0.6.0.apk"');
    expect(res.headers.get("content-length")).toBe("300000");
    expect(bytes).toEqual(file);
    expect(source.asked).toEqual([{ url: sourceFor("0.6.0"), method: "GET" }]);
  });

  it("latest is LATEST_VERSION", async () => {
    const file = apk(1000, 3);
    const source = fakeSource({ [sourceFor(env.LATEST_VERSION)]: file });
    setApkFetcher(source.fetch);
    const { res, bytes } = await download("/v1/apk/latest");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-disposition")).toBe(`attachment; filename="wordsmith-${env.LATEST_VERSION}.apk"`);
    expect(bytes).toEqual(file);
  });

  it("passes a body of unknown length straight through", async () => {
    const file = apk(5000);
    setApkFetcher(fakeSource({ [sourceFor("0.6.0")]: file }, { lengthless: true }).fetch);
    const { res, bytes } = await download("/v1/apk/0.6.0");
    expect(res.status).toBe(200);
    expect(bytes).toEqual(file);
  });

  it("answers HEAD with the size and no body", async () => {
    const source = fakeSource({ [sourceFor("0.6.0")]: apk(4096) });
    setApkFetcher(source.fetch);
    const { res } = await download("/v1/apk/0.6.0", "HEAD");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-length")).toBe("4096");
    expect(res.headers.get("content-type")).toBe(APK_TYPE);
    expect(source.asked).toEqual([{ url: sourceFor("0.6.0"), method: "HEAD" }]);
  });

  it("is a 404 for a version that isn't published yet, which the app reads as still on its way", async () => {
    setApkFetcher(fakeSource({}).fetch);
    const { res } = await download("/v1/apk/9.9.9");
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "apk_not_found" });
  });

  it("is a 502 when the source fails or can't be reached", async () => {
    setApkFetcher(fakeSource({}, { status: 500 }).fetch);
    expect((await download("/v1/apk/0.6.0")).res.status).toBe(502);
    setApkFetcher(fakeSource({}, { fail: true }).fetch);
    const { res } = await download("/v1/apk/0.6.0");
    expect(res.status).toBe(502);
    expect(await res.json()).toEqual({ error: "apk_unavailable" });
  });

  it("only takes version numbers, and never asks the source for anything else", async () => {
    const source = fakeSource({});
    setApkFetcher(source.fetch);
    for (const bad of ["0.6", "v0.6.0", "0.6.0.1", "..%2F..%2Fsecrets", "0.6.0%3Fx%3D1", "LATEST", "12345.0.0"]) {
      const { res } = await download(`/v1/apk/${bad}`);
      expect(res.status, bad).toBe(404);
    }
    expect(source.asked).toEqual([]);
  });
});

describe("GET /v1/version", () => {
  it("points the updater at this server, never at the source", async () => {
    const ctx = createExecutionContext();
    const res = await worker.fetch(new Request("https://wordsmith-api.example/v1/version"), env, ctx);
    expect((await res.json()) as unknown).toMatchObject({ apk: `https://wordsmith-api.example/v1/apk/${env.LATEST_VERSION}` });
  });

  it("has no APK without a source", () => {
    expect(versionInfo({ LATEST_VERSION: "1.0.0", MIN_SUPPORTED_VERSION: "0.1.0" }, BASE).apk).toBeNull();
    expect(versionInfo({ LATEST_VERSION: "1.0.0", MIN_SUPPORTED_VERSION: "0.1.0", APK_SOURCE_URL: "" }, BASE).apk).toBeNull();
  });
});
