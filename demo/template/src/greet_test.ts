import { test } from "node:test";
import assert from "node:assert/strict";
import { greet } from "./greet.ts";

test("greet says hello by name", () => {
  assert.equal(greet("Adam"), "Hello, Adam!");
});
