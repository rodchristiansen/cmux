import { describe, expect, test } from "bun:test";

import { buildAfterSignInRedirectPath } from "./auth-handler-url";

describe("auth handler redirect path", () => {
  test("preserves after_auth_return_to for signed-in sign-in route skips", () => {
    expect(
      buildAfterSignInRedirectPath({
        after_auth_return_to:
          "http://localhost:4310/handler/after-sign-in?native_app_return_to=cmux-dev-desktop-mobile-e2e://auth-callback",
      }),
    ).toBe(
      "/handler/after-sign-in?after_auth_return_to=http%3A%2F%2Flocalhost%3A4310%2Fhandler%2Fafter-sign-in%3Fnative_app_return_to%3Dcmux-dev-desktop-mobile-e2e%3A%2F%2Fauth-callback",
    );
  });

  test("preserves direct native_app_return_to for signed-in sign-in route skips", () => {
    expect(
      buildAfterSignInRedirectPath({
        native_app_return_to: "cmux-dev-desktop-mobile-e2e://auth-callback",
      }),
    ).toBe(
      "/handler/after-sign-in?native_app_return_to=cmux-dev-desktop-mobile-e2e%3A%2F%2Fauth-callback",
    );
  });
});
