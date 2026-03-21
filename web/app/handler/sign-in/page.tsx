import { StackHandler } from "@stackframe/stack";
import { redirect } from "next/navigation";

import { buildAfterSignInRedirectPath } from "@/lib/auth-handler-url";
import { stackServerApp } from "@/lib/stack";

type SignInPageProps = {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

export const dynamic = "force-dynamic";

export default async function SignInPage({ searchParams: searchParamsPromise }: SignInPageProps) {
  const searchParams = await searchParamsPromise;
  const user = await stackServerApp.getUser({ or: "return-null" });

  if (user) {
    redirect(buildAfterSignInRedirectPath(searchParams));
  }

  return (
    <StackHandler
      fullPage
      app={stackServerApp}
      params={{ stack: ["sign-in"] }}
      searchParams={searchParams}
    />
  );
}
