import { StackServerApp } from "@stackframe/stack";
import { stackEnv } from "./stack-env";

export const stackServerApp = new StackServerApp({
  projectId: stackEnv.NEXT_PUBLIC_STACK_PROJECT_ID,
  publishableClientKey: stackEnv.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY,
  secretServerKey: stackEnv.STACK_SECRET_SERVER_KEY,
  tokenStore: "nextjs-cookie",
  urls: {
    afterSignIn: "/handler/after-sign-in",
    afterSignUp: "/handler/after-sign-in",
  },
});
