import { describe, it, expect } from "vitest";
import { hashPassword, timingSafeEqual, isValidKeyField } from "../src/auth";

describe("Auth Utilities", () => {
  it("generates deterministic SHA-256 password hash", async () => {
    const hash1 = await hashPassword("mySecretPassword123");
    const hash2 = await hashPassword("mySecretPassword123");
    const diffHash = await hashPassword("differentPassword");

    expect(typeof hash1).toBe("string");
    expect(hash1.length).toBe(64); // SHA-256 hex length
    expect(hash1).toBe(hash2);
    expect(hash1).not.toBe(diffHash);
  });

  it("safely compares strings with timingSafeEqual", () => {
    expect(timingSafeEqual("abc123xyz", "abc123xyz")).toBe(true);
    expect(timingSafeEqual("abc123xyz", "abc123xyw")).toBe(false);
    expect(timingSafeEqual("short", "longer_string")).toBe(false);
  });

  it("validates valid key fields", () => {
    expect(isValidKeyField("valid_user")).toBe(true);
    expect(isValidKeyField("user-123")).toBe(true);
    expect(isValidKeyField("")).toBe(false);
    expect(isValidKeyField("invalid:user")).toBe(false); // contains colon
    expect(isValidKeyField(null)).toBe(false);
    expect(isValidKeyField(undefined)).toBe(false);
  });
});
