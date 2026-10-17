/** A small WebSocket test client for the hub and rooms. */

import { request, type Client } from "./helpers";

export type Message = Record<string, any> & { op: string };

export interface Socket {
  readonly ws: WebSocket;
  readonly protocol: string | null;
  /** Every message received so far. */
  readonly seen: Message[];
  /** Resolves with the next unread message whose top-level fields equal `match` (waiting up to `ms`). */
  next(match?: Partial<Message>, ms?: number): Promise<Message>;
  /** Unread messages up to the reply to a deliberately bad message (rooms answer in order). */
  drain(): Promise<Message[]>;
  send(message: unknown): void;
  readonly closed: Promise<{ code: number; reason: string }>;
}

/** Opens a WebSocket on `path` as `c`, offering `wordsmith.v1, <token>`. Throws unless it upgrades. */
export async function connect(c: Client, path: string): Promise<Socket> {
  const res = await openSocket(c, path);
  if (res.status !== 101) throw new Error(`upgrade failed: ${res.status} ${await res.text()}`);
  const ws = res.webSocket!;
  ws.accept();

  const seen: Message[] = [];
  let read = 0;
  let wake: (() => void) | null = null;
  ws.addEventListener("message", (e) => {
    seen.push(JSON.parse(e.data as string) as Message);
    wake?.();
  });
  const closed = new Promise<{ code: number; reason: string }>((resolve) =>
    ws.addEventListener("close", (e) => resolve({ code: e.code, reason: e.reason })),
  );

  const matches = (m: Message, want: Partial<Message>) => Object.entries(want).every(([k, v]) => m[k] === v);
  const next = async (want: Partial<Message> = {}, ms = 3000): Promise<Message> => {
    const deadline = Date.now() + ms;
    for (;;) {
      while (read < seen.length) {
        const m = seen[read++]!;
        if (matches(m, want)) return m;
      }
      if (Date.now() > deadline) throw new Error(`no message matching ${JSON.stringify(want)}; saw ${JSON.stringify(seen)}`);
      await new Promise<void>((resolve) => {
        wake = resolve;
        setTimeout(resolve, 25);
      });
    }
  };

  return {
    ws,
    protocol: res.headers.get("sec-websocket-protocol"),
    seen,
    next,
    async drain() {
      const from = read;
      ws.send('{"op":"NOT_A_THING"}');
      await next({ op: "ERROR", code: path.startsWith("/v1/ws/hub") ? "unknown_op" : "bad_message" });
      return seen.slice(from, read - 1);
    },
    send: (message) => ws.send(typeof message === "string" ? message : JSON.stringify(message)),
    closed,
  };
}

/** The raw upgrade response, for testing refusals. */
export function openSocket(c: Client, path: string): Promise<Response> {
  return request(path, { headers: { upgrade: "websocket", "sec-websocket-protocol": `wordsmith.v1, ${c.token}` } });
}

export const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
