import { describe, expect, test } from "bun:test";

import {
  buildNativeAppHref,
  extractNativeAppHref,
  isAllowedNativeAppHref,
} from "./native-app-deeplink";

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

  test("extracts nested native callback from after_auth_return_to URL", () => {
    expect(
      extractNativeAppHref(
        null,
        "http://127.0.0.1:4310/handler/after-sign-in?native_app_return_to=cmux-dev-desktop-mobile-e2e://auth-callback",
      ),
    ).toBe("cmux-dev-desktop-mobile-e2e://auth-callback");
  });
});
