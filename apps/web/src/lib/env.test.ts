import { describe, expect, it } from "vitest";
import { parseServerEnv } from "./env";

describe("parseServerEnv", () => {
  it("defaults to Base Sepolia with no database", () => {
    expect(parseServerEnv({})).toEqual({ CHAIN_ID: 84532, DATABASE_URL: undefined });
  });

  it("accepts a Postgres URL", () => {
    const env = parseServerEnv({ DATABASE_URL: "postgresql://u:p@host.neon.tech/db?sslmode=require" });
    expect(env.DATABASE_URL).toContain("neon.tech");
  });

  it("rejects a malformed database URL", () => {
    expect(() => parseServerEnv({ DATABASE_URL: "not a url" })).toThrow(/DATABASE_URL/);
  });

  it("refuses any chain other than Base Sepolia", () => {
    expect(() => parseServerEnv({ CHAIN_ID: "8453" })).toThrow(/only Base Sepolia/);
  });
});
