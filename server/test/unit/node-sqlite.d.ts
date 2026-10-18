/**
 * The part of Node's built-in SQLite (Node 22.13+) the unit tests use to run
 * generated SQL; the project has no @types/node.
 */
declare module "node:sqlite" {
  export class DatabaseSync {
    constructor(path: string);
    exec(sql: string): void;
    prepare(sql: string): {
      run(...params: unknown[]): { changes: number | bigint };
      all(...params: unknown[]): unknown[];
    };
  }
}
