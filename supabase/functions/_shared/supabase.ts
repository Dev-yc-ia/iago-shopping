import { createClient, type SupabaseClient, type User } from "npm:@supabase/supabase-js@2";
import { HttpError } from "./response.ts";

function env(name: string): string {
  return Deno.env.get(name)?.trim() || "";
}

function firstJsonKey(name: string): string {
  const raw = env(name);
  if (!raw) return "";

  try {
    const parsed = JSON.parse(raw) as Record<string, string>;
    return parsed.default || Object.values(parsed).find(Boolean) || "";
  } catch {
    return "";
  }
}

export function supabaseUrl(): string {
  const value = env("SUPABASE_URL");
  if (!value) throw new HttpError(503, "SUPABASE_URL não está disponível no runtime da Edge Function.");
  return value.replace(/\/+$/, "");
}

export function supabasePublishableKey(): string {
  const value = firstJsonKey("SUPABASE_PUBLISHABLE_KEYS")
    || env("SUPABASE_PUBLISHABLE_KEY")
    || env("SUPABASE_ANON_KEY");
  if (!value) throw new HttpError(503, "Chave pública/publishable do Supabase não está disponível no runtime.");
  return value;
}

export function supabaseSecretKey(): string {
  const value = firstJsonKey("SUPABASE_SECRET_KEYS")
    || env("SUPABASE_SECRET_KEY")
    || env("SUPABASE_SERVICE_ROLE_KEY");
  if (!value) {
    throw new HttpError(
      503,
      "Chave administrativa do Supabase não está disponível no runtime da Edge Function.",
    );
  }
  return value;
}

export function bearerToken(request: Request): string {
  const authorization = request.headers.get("authorization") || "";
  const [scheme, token] = authorization.split(/\s+/, 2);
  if (scheme?.toLowerCase() !== "bearer" || !token) {
    throw new HttpError(401, "Sessão obrigatória para operação de pagamento.");
  }
  return token.trim();
}

function baseClient(key: string, headers: Record<string, string> = {}): SupabaseClient {
  return createClient(supabaseUrl(), key, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
    global: { headers },
  });
}

export async function userSupabaseClient(request: Request): Promise<{
  supabase: SupabaseClient;
  user: User;
  userJwt: string;
}> {
  const userJwt = bearerToken(request);
  const supabase = baseClient(supabasePublishableKey(), {
    authorization: `Bearer ${userJwt}`,
  });

  const { data, error } = await supabase.auth.getUser(userJwt);
  if (error || !data.user) {
    throw new HttpError(401, "Token de sessão inválido.");
  }

  return { supabase, user: data.user, userJwt };
}

export function adminSupabaseClient(): SupabaseClient {
  return baseClient(supabaseSecretKey());
}

export async function callRpc(
  supabase: SupabaseClient,
  functionName: string,
  payload: Record<string, unknown> = {},
): Promise<unknown> {
  const { data, error } = await supabase.rpc(functionName, payload);
  if (error) {
    const status = typeof error.status === "number" ? error.status : 400;
    throw new HttpError(status, error.message || "RPC Supabase recusou a operação.");
  }
  return data;
}
