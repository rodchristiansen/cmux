import { describe, expect, test } from "bun:test";

import { buildNativeAppHref, isAllowedNativeAppHref } from "./native-app-deeplink";

describe("native app deeplink helper", () => {
  test("allows cmux callback deeplinks", () => {
    expect(isAllowedNativeAppHref("cmux://auth-callback")).toBe(true);
    expect(isAllowedNativeAppHref("cmux-dev-auth-mobile://auth-callback")).toBe(true);
  });

  test("rejects non-cmux custom schemes", () => {
    expect(isAllowedNativeAppHref("manaflow://auth-callback")).toBe(false);
    expect(isAllowedNativeAppHref("evil://auth-callback")).toBe(false);
    expect(isAllowedNativeAppHref("cmux://wrong-path")).toBe(false);
  });

  test("injects stack tokens into a valid native deeplink", () => {
    expect(
      buildNativeAppHref(
        "cmux-dev-auth-mobile://auth-callback",
        "refresh-123",
        "[\"refresh-123\",\"access-456\"]",
      ),
    ).toBe(
      "cmux-dev-auth-mobile://auth-callback?stack_refresh=refresh-123&stack_access=%5B%22refresh-123%22%2C%22access-456%22%5D",
    );
  });
});
