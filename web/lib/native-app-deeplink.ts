const DEFAULT_NATIVE_APP_CALLBACK_HREF = "cmux://auth-callback";

function isCmuxScheme(protocol: string) {
  const normalized = protocol.toLowerCase();
  return normalized === "cmux:" || /^cmux-dev(?:-[a-z0-9-]+)?:$/.test(normalized);
}

export function isAllowedNativeAppHref(target: string): boolean {
  try {
    const url = new URL(target);
    const callbackTarget = (url.pathname.replace(/^\/+/, "") || url.host).toLowerCase();
    if (callbackTarget !== "auth-callback") {
      return false;
    }

    return isCmuxScheme(url.protocol);
  } catch {
    return false;
  }
}

export function extractNativeAppHref(
  nativeAppReturnTo: string | null | undefined,
  afterAuthReturnTo: string | null | undefined,
): string | null {
  if (nativeAppReturnTo && isAllowedNativeAppHref(nativeAppReturnTo)) {
    return nativeAppReturnTo;
  }

  if (!afterAuthReturnTo) {
    return null;
  }

  if (isAllowedNativeAppHref(afterAuthReturnTo)) {
    return afterAuthReturnTo;
  }

  try {
    const nestedNativeAppReturnTo = new URL(afterAuthReturnTo).searchParams.get(
      "native_app_return_to",
    );
    if (nestedNativeAppReturnTo && isAllowedNativeAppHref(nestedNativeAppReturnTo)) {
      return nestedNativeAppReturnTo;
    }
  } catch {}

  return null;
}

export function buildNativeAppHref(
  baseHref: string | null,
  stackRefreshToken: string | undefined,
  stackAccessCookie: string | undefined,
  fallbackHref: string = DEFAULT_NATIVE_APP_CALLBACK_HREF,
): string | null {
  const resolvedBaseHref = baseHref ?? fallbackHref;
  if (!isAllowedNativeAppHref(resolvedBaseHref)) {
    return null;
  }
  if (!stackRefreshToken || !stackAccessCookie) {
    return resolvedBaseHref;
  }

  const url = new URL(resolvedBaseHref);
  url.searchParams.set("stack_refresh", stackRefreshToken);
  url.searchParams.set("stack_access", stackAccessCookie);
  return url.toString();
}
