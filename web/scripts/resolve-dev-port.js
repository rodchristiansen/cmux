const DEFAULT_DEV_PORT = 3777;

export function resolveDevPort(env = process.env) {
  const rawPort = env.CMUX_PORT ?? env.PORT;
  if (!rawPort) {
    return DEFAULT_DEV_PORT;
  }

  const parsed = Number.parseInt(rawPort, 10);
  if (Number.isNaN(parsed) || parsed <= 0) {
    return DEFAULT_DEV_PORT;
  }

  return parsed;
}
