import { describe, it, expect, beforeEach } from "vitest";
import app from "../src/index";
import { createMockD1 } from "./mock-d1";
import { Env } from "../src/types";

describe("KOReader Kosync API Endpoints", () => {
  let env: Env;

  beforeEach(() => {
    env = {
      DB: createMockD1(),
    };
  });

  describe("Health Check Endpoints", () => {
    it("returns 200 OK for /health", async () => {
      const res = await app.request("/health", {}, env);
      expect(res.status).toBe(200);
      const data = await res.json<any>();
      expect(data.status).toBe("ok");
      expect(data.state).toBe("OK");
    });

    it("returns 200 OK for /healthcheck", async () => {
      const res = await app.request("/healthcheck", {}, env);
      expect(res.status).toBe(200);
      const data = await res.json<any>();
      expect(data.state).toBe("OK");
    });
  });

  describe("User Registration (/users/create)", () => {
    it("registers a new user successfully", async () => {
      const res = await app.request(
        "/users/create",
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ username: "testuser", password: "secretpassword" }),
        },
        env
      );

      expect(res.status).toBe(201);
      const data = await res.json<any>();
      expect(data.username).toBe("testuser");
    });

    it("rejects duplicate user with 402 / code 2002", async () => {
      // First registration
      await app.request(
        "/users/create",
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ username: "existinguser", password: "secretpassword" }),
        },
        env
      );

      // Duplicate registration
      const res = await app.request(
        "/users/create",
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ username: "existinguser", password: "secretpassword" }),
        },
        env
      );

      expect(res.status).toBe(402);
      const data = await res.json<any>();
      expect(data.code).toBe(2002);
      expect(data.message).toBe("Username is already registered.");
    });

    it("rejects invalid characters (colons) in username", async () => {
      const res = await app.request(
        "/users/create",
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ username: "user:with:colon", password: "secretpassword" }),
        },
        env
      );

      expect(res.status).toBe(403);
      const data = await res.json<any>();
      expect(data.code).toBe(2003);
    });
  });

  describe("User Authentication (/users/auth)", () => {
    beforeEach(async () => {
      // Register test user
      await app.request(
        "/users/create",
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ username: "reader1", password: "mypassword" }),
        },
        env
      );
    });

    it("authenticates via x-auth-user and x-auth-key headers", async () => {
      const res = await app.request(
        "/users/auth",
        {
          method: "GET",
          headers: {
            "x-auth-user": "reader1",
            "x-auth-key": "mypassword",
          },
        },
        env
      );

      expect(res.status).toBe(200);
      const data = await res.json<any>();
      expect(data.authorized).toBe("OK");
    });

    it("authenticates via POST JSON body", async () => {
      const res = await app.request(
        "/users/auth",
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ username: "reader1", password: "mypassword" }),
        },
        env
      );

      expect(res.status).toBe(200);
      const data = await res.json<any>();
      expect(data.authorized).toBe("OK");
    });

    it("rejects invalid password with 401 Unauthorized", async () => {
      const res = await app.request(
        "/users/auth",
        {
          method: "GET",
          headers: {
            "x-auth-user": "reader1",
            "x-auth-key": "wrongpassword",
          },
        },
        env
      );

      expect(res.status).toBe(401);
      const data = await res.json<any>();
      expect(data.code).toBe(2001);
      expect(data.message).toBe("Unauthorized");
    });

    it("rejects non-existent user with 401 Unauthorized", async () => {
      const res = await app.request(
        "/users/auth",
        {
          method: "GET",
          headers: {
            "x-auth-user": "nonexistent",
            "x-auth-key": "somepassword",
          },
        },
        env
      );

      expect(res.status).toBe(401);
      const data = await res.json<any>();
      expect(data.code).toBe(2001);
    });
  });

  describe("Reading Progress Synchronization (/syncs/progress)", () => {
    const username = "kindle_user";
    const userKey = "kindle_pass";
    const docHash = "0b229176d4e8db7f6d2b5a4952368d7a";

    beforeEach(async () => {
      await app.request(
        "/users/create",
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ username, password: userKey }),
        },
        env
      );
    });

    it("returns empty object for non-existent document progress", async () => {
      const res = await app.request(
        `/syncs/progress/${docHash}`,
        {
          method: "GET",
          headers: {
            "x-auth-user": username,
            "x-auth-key": userKey,
          },
        },
        env
      );

      expect(res.status).toBe(200);
      const data = await res.json<any>();
      expect(data).toEqual({});
    });

    it("requires authentication for progress operations", async () => {
      const getRes = await app.request(`/syncs/progress/${docHash}`, {}, env);
      expect(getRes.status).toBe(401);

      const putRes = await app.request(
        "/syncs/progress",
        {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            document: docHash,
            percentage: 0.5,
            progress: "/body/DocFragment[5]/p[1]",
            device: "Kindle Paperwhite",
          }),
        },
        env
      );
      expect(putRes.status).toBe(401);
    });

    it("saves and updates reading progress", async () => {
      // 1. Initial progress update
      const putRes1 = await app.request(
        "/syncs/progress",
        {
          method: "PUT",
          headers: {
            "Content-Type": "application/json",
            "x-auth-user": username,
            "x-auth-key": userKey,
          },
          body: JSON.stringify({
            document: docHash,
            percentage: 0.318,
            progress: "/body/DocFragment[20]/body/p[22]/img.0",
            device: "Kindle Paperwhite",
            device_id: "dev_kindle_01",
          }),
        },
        env
      );

      expect(putRes1.status).toBe(200);
      const putData1 = await putRes1.json<any>();
      expect(putData1.document).toBe(docHash);
      expect(typeof putData1.timestamp).toBe("number");

      // 2. Fetch saved progress
      const getRes1 = await app.request(
        `/syncs/progress/${docHash}`,
        {
          method: "GET",
          headers: {
            "x-auth-user": username,
            "x-auth-key": userKey,
          },
        },
        env
      );

      expect(getRes1.status).toBe(200);
      const getData1 = await getRes1.json<any>();
      expect(getData1.document).toBe(docHash);
      expect(getData1.percentage).toBeCloseTo(0.318);
      expect(getData1.progress).toBe("/body/DocFragment[20]/body/p[22]/img.0");
      expect(getData1.device).toBe("Kindle Paperwhite");
      expect(getData1.device_id).toBe("dev_kindle_01");
      expect(typeof getData1.timestamp).toBe("number");

      // 3. Update to further progress from another device
      const putRes2 = await app.request(
        "/syncs/progress",
        {
          method: "PUT",
          headers: {
            "Content-Type": "application/json",
            "x-auth-user": username,
            "x-auth-key": userKey,
          },
          body: JSON.stringify({
            document: docHash,
            percentage: 0.582,
            progress: "/body/DocFragment[35]/body/p[10]/text.1",
            device: "KOReader Android",
            device_id: "dev_android_02",
          }),
        },
        env
      );

      expect(putRes2.status).toBe(200);

      // 4. Verify updated state
      const getRes2 = await app.request(
        `/syncs/progress/${docHash}`,
        {
          method: "GET",
          headers: {
            "x-auth-user": username,
            "x-auth-key": userKey,
          },
        },
        env
      );

      const getData2 = await getRes2.json<any>();
      expect(getData2.percentage).toBeCloseTo(0.582);
      expect(getData2.progress).toBe("/body/DocFragment[35]/body/p[10]/text.1");
      expect(getData2.device).toBe("KOReader Android");
    });
  });
});
