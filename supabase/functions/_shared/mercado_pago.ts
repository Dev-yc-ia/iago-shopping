import { HttpError } from "./response.ts";
import { supabaseUrl } from "./supabase.ts";

const MERCADO_PAGO_API_BASE = "https://api.mercadopago.com";
const EMPTY_LOG_VALUE = "VAZIO";

type JsonRecord = Record<string, unknown>;

function rawEnv(name: string): string {
  return Deno.env.get(name) || "";
}

function env(name: string): string {
  return rawEnv(name).trim();
}

function asRecord(value: unknown): JsonRecord {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as JsonRecord
    : {};
}

function present(value: unknown): unknown {
  return value === null || value === undefined || value === "" ? EMPTY_LOG_VALUE : value;
}

function maskSecret(value: unknown): string {
  const text = String(value || "").trim();
  if (!text) return EMPTY_LOG_VALUE;
  if (text.length <= 12) return `${text.slice(0, 3)}...`;
  return `${text.slice(0, 12)}...${text.slice(-6)}`;
}

function maskPayload(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(maskPayload);
  if (!value || typeof value !== "object") return value ?? EMPTY_LOG_VALUE;

  return Object.fromEntries(
    Object.entries(value as JsonRecord).map(([key, item]) => {
      const normalized = key.toLowerCase();
      if (["access_token", "authorization", "jwt", "service_role", "service_role_key", "token"].includes(normalized)) {
        return [key, maskSecret(item)];
      }
      return [key, maskPayload(item)];
    }),
  );
}

function maskHeaders(headers: JsonRecord): JsonRecord {
  return Object.fromEntries(
    Object.entries(headers).map(([key, value]) => {
      if (key.toLowerCase() === "authorization") {
        const [scheme, token] = String(value || "").split(/\s+/, 2);
        return [key, token ? `${scheme} ${maskSecret(token)}` : maskSecret(value)];
      }
      return [key, value || EMPTY_LOG_VALUE];
    }),
  );
}

function credentialEnvironment(value: string): string {
  const normalized = value.trim().toUpperCase();
  if (normalized.startsWith("APP_USR")) return "production";
  if (normalized.startsWith("TEST")) return "test";
  return "unknown";
}

function credentialDiagnostic(name: string): JsonRecord {
  const raw = rawEnv(name);
  const trimmed = raw.trim();
  return {
    source: `edge-secret:${name}`,
    present: Boolean(trimmed),
    same_after_trim: raw === trimmed,
    environment: credentialEnvironment(trimmed),
  };
}

function assertProviderEnvironment(accessTokenEnvironment: string): void {
  const provider = providerMode();
  if (provider === "prod" && accessTokenEnvironment === "test") {
    throw new HttpError(503, "MERCADO_PAGO_ACCESS_TOKEN de teste configurado com provider de produção.");
  }
  if (provider === "sandbox" && accessTokenEnvironment === "production") {
    throw new HttpError(503, "MERCADO_PAGO_ACCESS_TOKEN de produção configurado com provider sandbox.");
  }
}

export function providerMode(): string {
  return env("PAYMENT_PROVIDER").toLowerCase() === "mercado_pago_prod" ? "prod" : "sandbox";
}

export function isMercadoPagoProvider(): boolean {
  return ["mercado_pago", "mercado_pago_sandbox", "mercado_pago_prod"].includes(
    env("PAYMENT_PROVIDER").toLowerCase(),
  );
}

export function paymentNotificationUrl(): string {
  return env("MERCADO_PAGO_NOTIFICATION_URL")
    || `${supabaseUrl()}/functions/v1/mercado-pago-webhook`;
}

function paymentExpirationIso(): string {
  const configured = Number(env("MERCADO_PAGO_PAYMENT_EXPIRATION_MINUTES") || "30");
  const minutes = Math.max(1, Math.min(Number.isFinite(configured) ? configured : 30, 1440));
  return new Date(Date.now() + minutes * 60_000).toISOString();
}

function buildIdempotencyKey(orderId: string, method: string): string {
  return `iago:${providerMode()}:${orderId}:${method}:${crypto.randomUUID()}`;
}

function buildExternalReference(orderId: string): string {
  return `iago:${providerMode()}:${orderId}:${crypto.randomUUID()}`;
}

export function createPaymentPayload(
  orderContext: JsonRecord,
  method: string,
  cardPayload: JsonRecord | null = null,
): { payload: JsonRecord; idempotencyKey: string; externalReference: string } {
  const orderId = String(orderContext.pedido_id || "");
  if (!orderId) throw new HttpError(400, "Contexto de pedido inválido para pagamento.");

  const externalReference = buildExternalReference(orderId);
  const idempotencyKey = buildIdempotencyKey(orderId, method);
  const amount = Number(orderContext.total);
  const description = `IAGO Shopping - Pedido #${orderContext.numero}`;
  const payerEmail = String(orderContext.cliente_email || "test_user_000000@testuser.com");

  const payload: JsonRecord = {
    transaction_amount: amount,
    description,
    external_reference: externalReference,
    payer: { email: payerEmail },
    metadata: {
      iago_pedido_id: orderId,
      iago_pedido_numero: orderContext.numero,
      provider_mode: providerMode(),
    },
  };

  const notificationUrl = paymentNotificationUrl();
  if (notificationUrl) payload.notification_url = notificationUrl;

  if (method === "pix") {
    payload.payment_method_id = "pix";
    payload.date_of_expiration = paymentExpirationIso();
    return { payload, idempotencyKey, externalReference };
  }

  const card = cardPayload || {};
  const token = card.token;
  const paymentMethodId = card.payment_method_id;
  if (!token || !paymentMethodId) {
    throw new HttpError(400, "Token e bandeira do cartão são obrigatórios.");
  }

  payload.token = token;
  payload.installments = Number(card.installments || 1);
  payload.payment_method_id = paymentMethodId;
  if (card.issuer_id) payload.issuer_id = card.issuer_id;
  if (card.payer) payload.payer = card.payer;

  return { payload, idempotencyKey, externalReference };
}

function mercadoPagoErrorMessage(action: string, payload: JsonRecord): string {
  const cause = Array.isArray(payload.cause) ? asRecord(payload.cause[0]) : {};
  const parts = [
    payload.message,
    payload.error,
    payload.status_detail,
    cause.code,
    cause.description,
  ].map((item) => String(item || "").trim()).filter(Boolean);

  return `Mercado Pago não aceitou ${action}: ${parts.join(" | ") || "resposta sem detalhe técnico."}`;
}

function raiseForMercadoPagoError(action: string, httpStatus: number, payload: JsonRecord): void {
  if (httpStatus < 400) return;
  throw new HttpError(httpStatus >= 500 ? 502 : 400, mercadoPagoErrorMessage(action, payload));
}

async function parseJsonResponse(response: Response): Promise<JsonRecord> {
  const raw = await response.text();
  if (!raw.trim()) return {};
  try {
    return JSON.parse(raw) as JsonRecord;
  } catch {
    return { message: raw };
  }
}

async function mercadoPagoRequest(
  path: string,
  options: { method?: string; payload?: JsonRecord; idempotencyKey?: string } = {},
): Promise<{ payload: JsonRecord; headers: JsonRecord; status: number; elapsedMs: number }> {
  const accessToken = env("MERCADO_PAGO_ACCESS_TOKEN");
  const diagnostic = credentialDiagnostic("MERCADO_PAGO_ACCESS_TOKEN");
  console.info("[MP-01] credential", diagnostic);

  if (!accessToken) {
    throw new HttpError(503, "MERCADO_PAGO_ACCESS_TOKEN não está configurado nas Secrets da Edge Function.");
  }
  assertProviderEnvironment(String(diagnostic.environment || "unknown"));

  const method = options.method || "GET";
  const headers: Record<string, string> = {
    authorization: `Bearer ${accessToken}`,
    accept: "application/json",
    "content-type": "application/json",
  };
  if (options.idempotencyKey) headers["x-idempotency-key"] = options.idempotencyKey;

  const started = performance.now();
  console.info("[IAGO Edge Mercado Pago] request", {
    provider: providerMode(),
    path,
    method,
    idempotency_key: present(options.idempotencyKey),
    headers: maskHeaders(headers),
    payload: maskPayload(options.payload || {}),
  });

  console.info("[MP-05] provider_auth_start", { provider: providerMode(), path, method });
  const response = await fetch(`${MERCADO_PAGO_API_BASE}${path}`, {
    method,
    headers,
    body: options.payload ? JSON.stringify(options.payload) : undefined,
  });
  const elapsedMs = Math.round(performance.now() - started);
  const responsePayload = await parseJsonResponse(response);
  const responseHeaders = Object.fromEntries(response.headers.entries());

  console.info("[MP-06] provider_auth_status", { http_status: response.status });
  console.info("[IAGO Edge Mercado Pago] response", {
    provider: providerMode(),
    path,
    method,
    http_status: response.status,
    elapsed_ms: elapsedMs,
    response_headers: responseHeaders,
    fields: {
      provider_status: present(responsePayload.status),
      payment_id: present(responsePayload.id),
      external_reference: present(responsePayload.external_reference),
      status_detail: present(responsePayload.status_detail),
      message: present(responsePayload.message),
    },
  });

  return {
    payload: responsePayload,
    headers: responseHeaders,
    status: response.status,
    elapsedMs,
  };
}

function parseProviderDate(value: unknown): Date | null {
  if (!value) return null;
  const parsed = new Date(String(value));
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function providerStatusForCheckout(payload: JsonRecord): string | null {
  const status = typeof payload.status === "string" ? payload.status : null;
  const expiration = parseProviderDate(payload.date_of_expiration);
  if (
    status
    && ["pending", "in_process", "action_required"].includes(status.toLowerCase())
    && expiration
    && expiration.getTime() <= Date.now()
  ) {
    return "expired";
  }
  return status;
}

export async function createMercadoPagoPayment(
  orderContext: JsonRecord,
  method: string,
  cardPayload: JsonRecord | null = null,
): Promise<JsonRecord> {
  const { payload: requestPayload, idempotencyKey, externalReference } = createPaymentPayload(
    orderContext,
    method,
    cardPayload,
  );
  const response = await mercadoPagoRequest("/v1/payments", {
    method: "POST",
    payload: requestPayload,
    idempotencyKey,
  });
  raiseForMercadoPagoError("a criação do pagamento", response.status, response.payload);

  const pointOfInteraction = asRecord(response.payload.point_of_interaction);
  const transactionData = asRecord(pointOfInteraction.transaction_data);
  const transactionDetails = asRecord(response.payload.transaction_details);
  const providerPaymentId = response.payload.id;
  const providerStatus = String(response.payload.status || "");

  if (!providerPaymentId) {
    throw new HttpError(
      502,
      "Mercado Pago criou uma resposta sem ID de pagamento; a tentativa não pode ser sincronizada.",
    );
  }

  return {
    provider_mode: providerMode(),
    provider_payment_id: String(providerPaymentId),
    provider_transaction_id: transactionDetails.transaction_id ? String(transactionDetails.transaction_id) : null,
    qr_code_base64: transactionData.qr_code_base64 || null,
    qr_code_url: transactionData.ticket_url || null,
    copia_cola: transactionData.qr_code || null,
    external_reference: response.payload.external_reference || externalReference,
    payment_url: response.payload.init_point || response.payload.sandbox_init_point || null,
    expiration_date: response.payload.date_of_expiration || requestPayload.date_of_expiration || null,
    provider_status: providerStatus || null,
    request_payload: requestPayload,
    response_payload: response.payload,
    response_headers: response.headers,
    http_status: response.status,
    tempo_resposta_ms: response.elapsedMs,
    idempotency_key: idempotencyKey,
    erro_tecnico: null,
    erro_negocio: method === "pix" && !transactionData.qr_code_base64 && !transactionData.qr_code && !transactionData.ticket_url
      ? "Mercado Pago criou o Pix, mas não retornou QR Code nem Pix Copia e Cola."
      : null,
  };
}

export async function getMercadoPagoPayment(providerPaymentId: string): Promise<JsonRecord> {
  const response = await mercadoPagoRequest(`/v1/payments/${encodeURIComponent(providerPaymentId)}`);
  raiseForMercadoPagoError("a consulta do pagamento", response.status, response.payload);
  const providerStatus = providerStatusForCheckout(response.payload);

  return {
    provider_status: providerStatus,
    provider_payload: response.payload,
    response_headers: response.headers,
    http_status: response.status,
    erro_tecnico: response.status < 500 ? null : response.payload.message || "Erro tecnico Mercado Pago.",
    erro_negocio: providerStatus === "expired" && response.payload.status !== "expired"
      ? "Pix expirado pela data de vencimento retornada pelo Mercado Pago."
      : null,
  };
}

export async function cancelMercadoPagoPayment(providerPaymentId: string): Promise<JsonRecord> {
  const response = await mercadoPagoRequest(`/v1/payments/${encodeURIComponent(providerPaymentId)}`, {
    method: "PUT",
    payload: { status: "cancelled" },
  });
  raiseForMercadoPagoError("o cancelamento do pagamento", response.status, response.payload);
  const providerStatus = response.payload.status || (response.status < 400 ? "cancelled" : null);

  return {
    provider_status: providerStatus,
    provider_payload: response.payload,
    response_headers: response.headers,
    http_status: response.status,
    tempo_resposta_ms: response.elapsedMs,
    erro_tecnico: response.status < 500 ? null : response.payload.message || "Erro tecnico Mercado Pago.",
    erro_negocio: response.status < 400 ? null : response.payload.message || "Cancelamento nao aceito pelo Mercado Pago.",
  };
}

function signaturePart(signatureHeader: string, key: string): string {
  for (const part of signatureHeader.split(",")) {
    const [name, value] = part.trim().split("=", 2);
    if (name === key && value) return value;
  }
  return "";
}

function webhookDataId(request: Request, payload: JsonRecord): string {
  const url = new URL(request.url);
  const bodyData = asRecord(payload.data);
  return String(
    url.searchParams.get("data.id")
      || url.searchParams.get("data_id")
      || bodyData.id
      || payload.id
      || "",
  );
}

async function hmacSha256Hex(secret: string, manifest: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(manifest));
  return Array.from(new Uint8Array(signature))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function timingSafeEqual(left: string, right: string): boolean {
  const leftBytes = new TextEncoder().encode(left);
  const rightBytes = new TextEncoder().encode(right);
  if (leftBytes.length !== rightBytes.length) return false;

  let mismatch = 0;
  for (let index = 0; index < leftBytes.length; index += 1) {
    mismatch |= leftBytes[index] ^ rightBytes[index];
  }
  return mismatch === 0;
}

export async function verifyMercadoPagoWebhook(request: Request, payload: JsonRecord): Promise<string> {
  const secret = env("MERCADO_PAGO_WEBHOOK_SECRET");
  if (!secret) {
    throw new HttpError(503, "MERCADO_PAGO_WEBHOOK_SECRET não está configurado nas Secrets da Edge Function.");
  }

  const signatureHeader = request.headers.get("x-signature") || "";
  const requestId = request.headers.get("x-request-id") || "";
  const timestamp = signaturePart(signatureHeader, "ts");
  const receivedSignature = signaturePart(signatureHeader, "v1");
  const dataId = webhookDataId(request, payload);

  if (!requestId || !timestamp || !receivedSignature || !dataId) {
    throw new HttpError(401, "Webhook Mercado Pago sem assinatura válida.");
  }

  const manifest = `id:${dataId};request-id:${requestId};ts:${timestamp};`;
  const expected = await hmacSha256Hex(secret, manifest);
  if (!timingSafeEqual(expected, receivedSignature)) {
    throw new HttpError(401, "Assinatura do webhook Mercado Pago inválida.");
  }

  return dataId;
}

export function mercadoPagoEngineMetadata(): JsonRecord {
  const publicKey = env("MERCADO_PAGO_PUBLIC_KEY") || null;
  const pollInterval = Number(env("MERCADO_PAGO_POLL_INTERVAL_MS") || "3000");

  return {
    provider: "mercado_pago",
    mode: "checkout_transparente_bricks",
    methods: ["pix", "cartao_debito", "cartao_credito"],
    future_provider: "mercado_pago",
    webhook_ready: Boolean(env("MERCADO_PAGO_WEBHOOK_SECRET") && paymentNotificationUrl()),
    public_key: publicKey,
    provider_mode: providerMode(),
    poll_interval_ms: Math.max(1500, Number.isFinite(pollInterval) ? pollInterval : 3000),
    scenarios: [],
    mock_config: null,
  };
}
