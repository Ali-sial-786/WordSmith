# Wordsmith API

The server side of Wordsmith: a Cloudflare Worker written in TypeScript, with
a D1 (SQLite) database. Durable Objects for presence (HubDO) and rooms
(RoomDO) come in M2 and M3. See [docs/TECH.md](../docs/TECH.md) for the plan.

M0 contains:

- **`src/index.ts`**: the router. Right now it serves `GET /v1/version` and `GET /v1/health`.
- **`migrations/0001_init.sql`**: the D1 schema from TECH.md §7.
- **`src/rules/`**: the game rules as pure functions with no I/O, so they're easy to test and tune. The Durable Objects will call them later, and the app's Dart engine mirrors them.

| File | Rules |
|---|---|
| `words.ts` | Normalising a guess (A–Z only), the 3-letter minimum, and checking a word can be made from the anvil letters |
| `heat.ts` | Heat tier from Smith Level, tier names, co-op and VS timers, and the median level for VS |
| `progression.ts` | XP curve, levels, ranks, hint unlocks, level-up rewards, XP per mode, and the Scrap Bin |
| `pickups.ts` | Campaign pickup seeding ([shared/pickups.md](../shared/pickups.md)) |
| `coop.ts` | Claim decisions, word points, MVP and stars |
| `vs.ts` | Round results, series clinch, sudden death and the podium |

## Routes

| Route | Response |
|---|---|
| `GET /v1/version` | `{"latest": "0.1.0", "minSupported": "0.1.0", "protocol": 1}`, from the `vars` in `wrangler.jsonc` |
| `GET /v1/health` | `{"ok": true}` |
| Any other path | `404 {"error": "not_found"}` |
| A known path with the wrong method | `405 {"error": "method_not_allowed"}` |

## Local development

You need Node 22.12 or newer. Local mode doesn't need a Cloudflare account or
`wrangler login`.

```sh
cd server
npm ci
npx wrangler d1 migrations apply wordsmith --local   # or: npm run db:migrate:local
npm run dev                                          # wrangler dev on http://localhost:8787
curl http://localhost:8787/v1/version
```

- `wrangler dev` runs the Worker and a local D1 database. The data lives in `.wrangler/state/`, which git ignores. Delete that folder to start over.
- To look inside the local database: `npx wrangler d1 execute wordsmith --local --command "SELECT name FROM sqlite_master WHERE type = 'table'"`
- To turn off Wrangler's telemetry, set `WRANGLER_SEND_METRICS=false`.

## Tests

```sh
npm run typecheck   # tsc --noEmit (strict)
npm test            # vitest run: both projects
npx vitest run --project rules    # just the rules
npx vitest run --project worker   # just the Worker
```

The tests run as two Vitest projects:

- **`rules`** (`test/rules/`) runs plain unit tests in Node. They include every test vector in `shared/pickups.md`.
- **`worker`** (`test/worker/`) runs the Worker inside the real `workerd` runtime using `@cloudflare/vitest-plugin`. That package is the new name of `@cloudflare/vitest-pool-workers`. Before each test file, `test/worker/setup.ts` applies `migrations/` to the test D1 database, skipping any already applied. The tests call the routes and query the schema.

## Changing the schema

Add a new numbered file such as `migrations/0002_something.sql`. Don't edit
a migration once it has been applied to the real database. Wrangler records
which migrations have been applied in the `d1_migrations` table.

## Later: deploying

Nothing is deployed yet, and there's no Cloudflare account set up for this
project. When there is:

1. Create the database with `npx wrangler d1 create wordsmith`. Paste the `database_id` it prints into `wrangler.jsonc`, replacing the all-zero placeholder.
2. Apply the migrations to it: `npx wrangler d1 migrations apply wordsmith --remote`.
3. Deploy with `npm run deploy`, which runs `wrangler deploy`.

CI deploys need the GitHub secrets `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID`. Neither is set up yet. To raise the app version
users are told about, change `LATEST_VERSION` and `MIN_SUPPORTED_VERSION` in
`wrangler.jsonc` and deploy.
