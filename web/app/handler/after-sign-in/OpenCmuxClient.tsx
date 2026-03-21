"use client";

import { useEffect } from "react";

export function OpenCmuxClient({ href }: { href: string }) {
  useEffect(() => {
    try {
      window.location.href = href;
    } catch {
      console.error("Failed to open cmux", href);
    }
  }, [href]);

  return (
    <div className="min-h-dvh flex items-center justify-center bg-white px-6 text-neutral-950">
      <div className="w-full max-w-md rounded-2xl border border-neutral-200 bg-white p-8 text-center">
        <h1 className="text-lg font-semibold">Opening cmux…</h1>
        <p className="mt-2 text-sm text-neutral-600">
          If it doesn&apos;t open automatically, use the button below.
        </p>
        <div className="mt-5">
          <a
            href={href}
            className="inline-flex items-center justify-center rounded-md bg-neutral-950 px-4 py-2 text-sm font-medium text-white hover:opacity-90"
          >
            Open cmux
          </a>
        </div>
      </div>
    </div>
  );
}
