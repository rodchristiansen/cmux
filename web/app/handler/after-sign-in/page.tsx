import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import type { RequestCookie } from "next/dist/compiled/@edge-runtime/cookies";

import { buildNativeAppHref, extractNativeAppHref } from "@/lib/native-app-deeplink";
import { stackServerApp } from "@/lib/stack";
import { stackEnv } from "@/lib/stack-env";
import { OpenCmuxClient } from "./OpenCmuxClient";

export const dynamic = "force-dynamic";

function findStackCookie(
  cookieStore: { getAll: () => RequestCookie[] },
  baseName: string,
): string | undefined {
  const allCookies = cookieStore.getAll();

  const hostPrefixedWithBranch = allCookies.find(
    (cookie) => cookie.name.startsWith(`__Host-${baseName}--`) && cookie.value,
  );
  if (hostPrefixedWithBranch) {
    return hostPrefixedWithBranch.value;
  }

  const hostPrefixed = allCookies.find(
    (cookie) => cookie.name === `__Host-${baseName}` && cookie.value,
  );
  if (hostPrefixed) {
    return hostPrefixed.value;
  }

  const securePrefixedWithBranch = allCookies.find(
    (cookie) => cookie.name.startsWith(`__Secure-${baseName}--`) && cookie.value,
  );
  if (securePrefixedWithBranch) {
    return securePrefixedWithBranch.value;
  }

  const securePrefixed = allCookies.find(
    (cookie) => cookie.name === `__Secure-${baseName}` && cookie.value,
  );
  if (securePrefixed) {
    return securePrefixed.value;
  }

  const plainWithBranch = allCookies.find(
    (cookie) => cookie.name.startsWith(`${baseName}--`) && cookie.value,
  );
  if (plainWithBranch) {
    return plainWithBranch.value;
  }

  const plain = allCookies.find((cookie) => cookie.name === baseName && cookie.value);
  return plain?.value;
}

type ParsedStackAccessCookie = {
  refreshToken?: string;
  accessToken?: string;
};

type ParsedStackRefreshCookie = {
  refreshToken?: string;
};

function normalizeCookieValue(value: string | undefined): string | undefined {
  if (!value) {
    return undefined;
  }

  if (!value.includes("%")) {
    return value;
  }

  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function parseStackAccessCookie(value: string | undefined): ParsedStackAccessCookie {
  const normalized = normalizeCookieValue(value);
  if (!normalized) {
    return {};
  }

  if (!normalized.startsWith("[")) {
    return { accessToken: normalized };
  }

  try {
    const parsed: unknown = JSON.parse(normalized);
    if (Array.isArray(parsed)) {
      const [refreshToken, accessToken] = parsed;
      if (typeof refreshToken === "string" && typeof accessToken === "string") {
        return { refreshToken, accessToken };
      }
    }
  } catch {}

  return {};
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function parseStackRefreshCookie(value: string | undefined): ParsedStackRefreshCookie {
  const normalized = normalizeCookieValue(value);
  if (!normalized) {
    return {};
  }

  if (!normalized.startsWith("{")) {
    return { refreshToken: normalized };
  }

  try {
    const parsed: unknown = JSON.parse(normalized);
    if (isRecord(parsed)) {
      const refreshTokenValue = parsed.refresh_token;
      if (typeof refreshTokenValue === "string") {
        return { refreshToken: refreshTokenValue };
      }
    }
  } catch {}

  return {};
}

function getSingleValue(value: string | string[] | undefined): string | null {
  if (Array.isArray(value)) {
    return value[0] ?? null;
  }
  return typeof value === "string" ? value : null;
}

function isRelativePath(target: string): boolean {
  if (!target || target.startsWith("//")) {
    return false;
  }
  return target.startsWith("/");
}

type AfterSignInPageProps = {
  searchParams?: Promise<Record<string, string | string[] | undefined>>;
};

export default async function AfterSignInPage({ searchParams: searchParamsPromise }: AfterSignInPageProps) {
  const stackCookies = await cookies();
  const refreshCookieBaseName = `stack-refresh-${stackEnv.NEXT_PUBLIC_STACK_PROJECT_ID}`;
  const stackRefreshCookieValue = findStackCookie(stackCookies, refreshCookieBaseName);
  const stackAccessCookieValue = findStackCookie(stackCookies, "stack-access");
  const parsedAccessCookie = parseStackAccessCookie(stackAccessCookieValue);
  const parsedRefreshCookie = parseStackRefreshCookie(stackRefreshCookieValue);

  let stackRefreshToken = parsedAccessCookie.refreshToken ?? parsedRefreshCookie.refreshToken;
  let stackAccessCookie = normalizeCookieValue(stackAccessCookieValue);
  let accessToken = parsedAccessCookie.accessToken;

  try {
    const user = await stackServerApp.getUser({ or: "return-null" });
    if (user) {
      const freshSession = await user.createSession({
        expiresInMillis: 30 * 24 * 60 * 60 * 1000,
      });
      const freshTokens = await freshSession.getTokens();
      if (freshTokens.refreshToken) {
        stackRefreshToken = freshTokens.refreshToken;
      }
      if (freshTokens.accessToken) {
        accessToken = freshTokens.accessToken;
      }
    }
  } catch {}

  if (stackRefreshToken && accessToken) {
    stackAccessCookie = JSON.stringify([stackRefreshToken, accessToken]);
  }

  const searchParams = await searchParamsPromise;
  const nativeAppReturnTo = getSingleValue(searchParams?.native_app_return_to);
  const afterAuthReturnTo = getSingleValue(searchParams?.after_auth_return_to);
  const resolvedNativeAppHref = extractNativeAppHref(
    nativeAppReturnTo,
    afterAuthReturnTo,
  );

  if (resolvedNativeAppHref) {
    const cmuxHref = buildNativeAppHref(
      resolvedNativeAppHref,
      stackRefreshToken,
      stackAccessCookie,
    );
    if (cmuxHref) {
      return <OpenCmuxClient href={cmuxHref} />;
    }
  }

  if (afterAuthReturnTo && isRelativePath(afterAuthReturnTo)) {
    redirect(afterAuthReturnTo);
  }

  const fallbackHref = buildNativeAppHref(
    null,
    stackRefreshToken,
    stackAccessCookie,
  );
  if (fallbackHref) {
    return <OpenCmuxClient href={fallbackHref} />;
  }

  redirect("/");
}
