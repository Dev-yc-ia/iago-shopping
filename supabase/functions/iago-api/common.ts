import type postgres from "npm:postgres@3.4.7";

export type Sql = ReturnType<typeof postgres> | postgres.TransactionSql;
export type Body = Record<string, unknown>;
export interface Context {
  sql: ReturnType<typeof postgres>;
  codigo: string;
  request: Request;
  url: URL;
}
export class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}
export function fail(status: number, message: string): never {
  throw new HttpError(status, message);
}
export async function bytes(request: Request, limit: number, message: string) {
  const reader = request.body?.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  if (reader) {
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > limit) {
          await reader.cancel();
          fail(413, message);
        }
        chunks.push(value);
      }
    } finally {
      reader.releaseLock();
    }
  }
  const result = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.length;
  }
  return result;
}
export async function body(request: Request, limit = 65536): Promise<Body> {
  const raw = await bytes(request, limit, "Corpo da requisição excede o limite.");
  let data: unknown;
  try { data = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw)); }
  catch { fail(422, "Dados inválidos."); }
  if (!data || typeof data !== "object" || Array.isArray(data)) fail(422, "Dados inválidos.");
  return data as Body;
}
export function string(data: Body, key: string, max = Infinity, min = 0) {
  const value = data[key];
  if (typeof value !== "string" || [...value].length > max ||
      [...value].length < min || value.includes("\0")) fail(422, "Dados inválidos.");
  return value;
}
export function uuid(value: unknown) {
  if (typeof value !== "string" || !/^[\da-f]{8}-(?:[\da-f]{4}-){3}[\da-f]{12}$/i.test(value)) {
    fail(422, "Identificador inválido.");
  }
  return value.toLowerCase();
}
export function date(value: unknown) {
  if (typeof value !== "string" || !/^\d{4}-\d\d-\d\d$/.test(value)) fail(422, "Data inválida.");
  const parsed = new Date(value);
  if (!Number.isFinite(+parsed) || parsed.toISOString().slice(0, 10) !== value ||
      value.startsWith("0000")) fail(422, "Data inválida.");
  return value;
}
export async function digest(value: string) {
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(hash), (b) => b.toString(16).padStart(2, "0")).join("");
}
export function errorCode(error: unknown) {
  const code = (error as { code?: unknown })?.code;
  return typeof code === "string" && /^[A-Z0-9_]{2,32}$/.test(code) ? code : "sem_codigo";
}
export async function lockEvent(c: Sql, codigo: string) {
  const [event] = await c`SELECT id FROM cadastro.eventos WHERE codigo=${codigo}`;
  if (!event) fail(409, "Evento sem cadastro. Execute a importação local.");
  await c`INSERT INTO operacao.controle_evento(evento_id) VALUES (${event.id}) ON CONFLICT DO NOTHING`;
  await c`SELECT evento_id FROM operacao.controle_evento WHERE evento_id=${event.id} FOR UPDATE`;
  return event.id;
}
