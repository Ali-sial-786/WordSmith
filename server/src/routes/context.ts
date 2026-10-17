import type { Env } from "../env";
import type { HubDO } from "../hub/hub";
import { ApiError } from "../http";
import { loadAccount, isSetUp, type SetUpAccount } from "../db/accounts";

/** What every handler gets. */
export interface RequestContext {
  readonly request: Request;
  readonly env: Env;
  readonly ctx: ExecutionContext;
  readonly params: Readonly<Record<string, string>>;
  /** Epoch ms, read once per request. */
  readonly now: number;
}

/** A handler behind auth: `uid` is the verified Firebase uid. */
export interface AuthedContext extends RequestContext {
  readonly uid: string;
}

/** The caller's account, which must have finished `POST /v1/me/setup`. */
export async function requireSetUp(c: AuthedContext): Promise<SetUpAccount> {
  const account = await loadAccount(c.env.DB, c.uid);
  if (account === null || !isSetUp(account)) {
    throw new ApiError(403, "setup_required", "Choose a username first (POST /v1/me/setup)");
  }
  return account;
}

/** The global hub (docs/TECH.md §2): always the instance named "global". */
export function hub(env: Env): DurableObjectStub<HubDO> {
  return env.HUB.get(env.HUB.idFromName("global"));
}

/**
 * Tells the hub about a change, without failing the request if it can't
 * be reached: presence is best-effort, and a reconnect fixes it.
 */
export async function notifyHub(env: Env, call: (stub: DurableObjectStub<HubDO>) => Promise<unknown>): Promise<void> {
  try {
    await call(hub(env));
  } catch (err) {
    console.error("hub notification failed", err);
  }
}
