import { Hono } from "hono";
import { Env } from "../types";

export const healthRouter = new Hono<{ Bindings: Env }>();

healthRouter.get("/health", (c) => {
  return c.json({
    status: "ok",
    state: "OK",
    service: "sink",
    version: "1.1.0",
    timestamp: Math.floor(Date.now() / 1000),
  });
});

healthRouter.get("/healthcheck", (c) => {
  return c.json({
    state: "OK",
    status: "ok",
    version: "1.1.0",
  });
});
