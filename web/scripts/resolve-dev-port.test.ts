import { describe, expect, test } from "bun:test";

import { resolveDevPort } from "./resolve-dev-port";

describe("resolveDevPort", () => {
  test("prefers CMUX_PORT over PORT", () => {
    expect(
      resolveDevPort({
        CMUX_PORT: "4310",
        PORT: "3777",
      }),
    ).toBe(4310);
  });

  test("falls back to PORT when CMUX_PORT is missing", () => {
    expect(
      resolveDevPort({
        PORT: "4555",
      }),
    ).toBe(4555);
  });

  test("falls back to default port when neither env var is set", () => {
    expect(resolveDevPort({})).toBe(3777);
  });
});
