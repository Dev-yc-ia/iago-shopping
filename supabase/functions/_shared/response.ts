import { corsHeaders, optionsResponse } from "./cors.ts";

export class HttpError extends Error {
  status: number;
  detail: unknown;

  constructor(status: number, detail: unknown) {
    super(typeof detail === "string" ? detail : "Erro na operação.");
    this.name = "HttpError";
    this.status = status;
    this.detail = detail;
  }
}

export function firstRow(value: unknown): Record<string, unknown> {
  if (Array.isArray(value)) return (value[0] || {}) as Record<string, unknown>;
  return (value || {}) as Record<string, unknown>;
}

export async function readJsonBody(request: Request): Promise<Record<string, unknown>> {
  const raw = await request.text();
  if (!raw.trim()) return {};

  try {
    return JSON.parse(raw) as Record<string, unknown>;
  } catch (error) {
    throw new HttpError(400, "JSON inválido.");
  }
}

export function jsonResponse(
  request: Request,
  body: unknown,
  status = 200,
  headers: HeadersInit = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders(request),
      "content-type": "application/json; charset=utf-8",
      ...headers,
    },
  });
}

export function errorResponse(request: Request, error: unknown): Response {
  if (error instanceof HttpError) {
    return jsonResponse(request, { detail: error.detail }, error.status);
  }

  const message = error instanceof Error ? error.message : "Erro interno.";
  console.error("[IAGO Edge] erro não tratado", { message });
  return jsonResponse(request, { detail: "Erro interno na função de pagamento." }, 500);
}

export async function withCors(
  request: Request,
  handler: () => Promise<Response> | Response,
): Promise<Response> {
  if (request.method === "OPTIONS") return optionsResponse(request);

  try {
    return await handler();
  } catch (error) {
    return errorResponse(request, error);
  }
}

export function assertMethod(request: Request, methods: string[]): void {
  if (!methods.includes(request.method)) {
    throw new HttpError(405, "Método não permitido.");
  }
}
