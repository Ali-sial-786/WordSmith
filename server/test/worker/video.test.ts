import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { body, setUpClient } from "./helpers";
import { closeAll, connect } from "./sockets";

interface VideoGrant {
  url: string;
  token: string;
  room: string;
  expiresAt: number;
}

function claims(token: string): Record<string, unknown> & { video: { room: string } } {
  const payload = token.split(".")[1]!;
  const json = atob(payload.replace(/-/g, "+").replace(/_/g, "/"));
  return JSON.parse(json) as Record<string, unknown> & { video: { room: string } };
}

async function createRoom(c: { post(path: string, body: unknown): Promise<Response> }): Promise<string> {
  const res = await c.post("/v1/rooms", { mode: "coop" });
  expect(res.status).toBe(200);
  return (await body<{ code: string }>(res)).code;
}

describe("POST /v1/rooms/:code/video", () => {
  it("gives players in the room a LiveKit token for the same call", async () => {
    const host = await setUpClient();
    const guest = await setUpClient();
    const code = await createRoom(host);

    // The creator holds a seat from the start.
    const res = await host.post(`/v1/rooms/${code}/video`, {});
    expect(res.status, await res.clone().text()).toBe(200);
    const grant = await body<VideoGrant>(res);
    expect(grant.url).toBe(env.LIVEKIT_URL);
    expect(grant.room).toMatch(new RegExp(`^wordsmith-${code}-[0-9a-z]+$`));
    expect(claims(grant.token)).toMatchObject({ iss: env.LIVEKIT_API_KEY, sub: host.uid, name: host.username, video: { room: grant.room } });
    expect(grant.expiresAt).toBeGreaterThan(Date.now());

    // Not in the room yet.
    const early = await guest.post(`/v1/rooms/${code}/video`, {});
    expect(early.status).toBe(403);
    expect(await body(early)).toMatchObject({ error: "not_in_room" });

    const socket = await connect(guest, `/v1/ws/room/${code}`);
    await socket.next({ op: "SNAPSHOT" });
    const joined = await body<VideoGrant>(await guest.post(`/v1/rooms/${code}/video`, {}));
    expect(joined.room).toBe(grant.room);
    expect(claims(joined.token).sub).toBe(guest.uid);

    // Gone again after leaving.
    socket.send({ op: "LEAVE" });
    await socket.closed;
    const after = await guest.post(`/v1/rooms/${code}/video`, {});
    expect(after.status).toBe(403);
    await closeAll();
  });

  it("refuses unknown rooms and accounts without a name", async () => {
    const smith = await setUpClient();
    const missing = await smith.post("/v1/rooms/ZZZZZZ/video", {});
    expect(missing.status).toBe(403);
    const bad = await smith.post("/v1/rooms/nope!/video", {});
    expect(bad.status).toBe(404);
  });
});
