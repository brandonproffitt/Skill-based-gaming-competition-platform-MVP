import { z } from "zod";

// Server-only configuration. Values are optional until the milestone that needs them,
// so the app can boot (and CI can build) without any accounts set up.
const serverEnvSchema = z.object({
  DATABASE_URL: z.url().optional(),
  CHAIN_ID: z.coerce.number().int().default(84532), // Base Sepolia
});

export type ServerEnv = z.infer<typeof serverEnvSchema>;

export function parseServerEnv(source: Record<string, string | undefined>): ServerEnv {
  const result = serverEnvSchema.safeParse(source);
  if (!result.success) {
    throw new Error(`Invalid environment configuration:\n${z.prettifyError(result.error)}`);
  }
  if (result.data.CHAIN_ID !== 84532) {
    // Testnet only until real money is explicitly approved.
    throw new Error(`CHAIN_ID ${result.data.CHAIN_ID} is not allowed; only Base Sepolia (84532) is enabled.`);
  }
  return result.data;
}

let cached: ServerEnv | undefined;

export function serverEnv(): ServerEnv {
  cached ??= parseServerEnv(process.env);
  return cached;
}
