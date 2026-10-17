import { describe, expect, it } from "vitest";
import { Router } from "../../src/router";

const router = new Router<string>([
  { method: "GET", path: "/v1/me", handler: "getMe" },
  { method: "DELETE", path: "/v1/me", handler: "deleteMe" },
  { method: "GET", path: "/v1/users/:username", handler: "getUser" },
  { method: "DELETE", path: "/v1/friends/:id", handler: "deleteFriend" },
]);

describe("Router", () => {
  it("matches exact paths by method", () => {
    expect(router.match("GET", "/v1/me")).toEqual({ kind: "found", handler: "getMe", params: {} });
    expect(router.match("DELETE", "/v1/me")).toMatchObject({ kind: "found", handler: "deleteMe" });
  });

  it("captures and decodes params", () => {
    expect(router.match("GET", "/v1/users/Ali_9")).toMatchObject({ kind: "found", params: { username: "Ali_9" } });
    expect(router.match("DELETE", "/v1/friends/a%3Ab")).toMatchObject({ params: { id: "a:b" } });
  });

  it("405s a known path with another method, listing what's allowed", () => {
    expect(router.match("POST", "/v1/me")).toEqual({ kind: "method_not_allowed", allow: ["GET", "DELETE"] });
  });

  it.each(["/", "/v1", "/v1/me/", "/v1/users", "/v1/users/", "/v1/users/a/b", "/v1/users/%E0%A4%A", "/v1/__proto__", "/v1/toString"])(
    "doesn't match %s",
    (path) => {
      expect(router.match("GET", path)).toEqual({ kind: "not_found" });
    },
  );
});
