import { spawn } from "node:child_process";

import { resolveDevPort } from "./resolve-dev-port.js";

const port = resolveDevPort(process.env);

const child = spawn("next", ["dev", "--port", String(port)], {
  stdio: "inherit",
  env: process.env,
  shell: process.platform === "win32",
});

child.on("exit", (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 0);
});
