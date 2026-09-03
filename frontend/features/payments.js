import { APP_CONFIG } from "../config/app.js";
import { getCurrentSession, getSupabaseClient } from "./auth.js";
import { recordEvent } from "../utils/analytics.js";

export const PAYMENT_METHOD_LABELS = {
  pix: "Pix",
  cartao_debito: "Cartão de débito",
  cartao_credito: "Cartão de crédito",
};

export const PAYMENT_STATUS_LABELS = {
  criado: "Pagamento criado",
  pendente: "Pagamento pendente",
  aprovado: "Pagamento aprovado",
  recusado: "Pagamento recusado",
  expirado: "Pagamento expirado",
  cancelado: "Pagamento cancelado",
};

export const DEFAULT_MOCK_PAYMENT_CONFIG = {
  scenario: "sempre_aprovar",
  delay_ms: 3500,
  timeout_ms: 9000,
  expiration_ms: 300000,
};

function wait(ms) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

function normalizePayment(data) {
  return Array.isArray(data) ? data[0] : data;
}

function responseErrorMessage(data) {
  if (!data?.detail) return "Payment Engine indisponível.";
  if (typeof data.detail === "string") return data.detail;
  if (Array.isArray(data.detail)) {
    return data.detail
      .map((item) => item?.msg || item?.message || item?.detail)
      .filter(Boolean)
      .join(" | ") || "Payment Engine recusou a operação.";
  }
  return data.detail.message || data.detail.detail || "Payment Engine recusou a operação.";
}

function getMockDelay(paymentEngine) {
  const config = paymentEngine?.mock_config || DEFAULT_MOCK_PAYMENT_CONFIG;
  const delay = Number(config.delay_ms || DEFAULT_MOCK_PAYMENT_CONFIG.delay_ms);
  return Math.max(800, Math.min(delay, 30000));
}

export function isMercadoPagoEngine(paymentEngine) {
  return paymentEngine?.provider === "mercado_pago";
}

async function apiPaymentRequest(endpoint, payload) {
  const session = await getCurrentSession();
  if (!session?.access_token) {
    throw new Error("Faça login para iniciar o pagamento.");
  }

  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
      Authorization: `Bearer ${session.access_token}`,
    },
    body: JSON.stringify(payload),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(responseErrorMessage(data));
  }
  return data;
}

export async function getPaymentEngineMetadata() {
  try {
    const response = await fetch(APP_CONFIG.paymentEngineEndpoint);
    if (!response.ok) throw new Error("Payment Engine indisponível.");
    return response.json();
  } catch (error) {
    console.warn(error.message);
    return {
      provider: APP_CONFIG.paymentProvider,
      mode: "local_simulation",
      methods: Object.keys(PAYMENT_METHOD_LABELS),
      future_provider: "mercado_pago",
      webhook_ready: true,
      scenarios: [],
      mock_config: DEFAULT_MOCK_PAYMENT_CONFIG,
    };
  }
}

export async function createPaymentAttempt(orderId, method = "pix") {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.rpc("shopping_pagamento_criar_rpc", {
    p_pedido_id: orderId,
    p_metodo: method,
  });
  if (error) throw error;

  const payment = normalizePayment(data);
  recordEvent("payment_attempt_create", { orderId, paymentId: payment?.id, method });
  return payment;
}

export async function processPaymentAttempt(paymentId) {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.rpc("shopping_pagamento_processar_rpc", {
    p_pagamento_id: paymentId,
  });
  if (error) throw error;

  const payment = normalizePayment(data);
  recordEvent("payment_provider_result", { paymentId, status: payment?.status });
  return payment;
}

export async function cancelPaymentAttempt(order, paymentEngine = null) {
  if (!order?.paymentId) {
    throw new Error("Nenhuma tentativa de pagamento ativa para cancelar.");
  }

  if (isMercadoPagoEngine(paymentEngine)) {
    const data = await apiPaymentRequest(APP_CONFIG.paymentCancelEndpoint, {
      payment_id: order.paymentId,
      provider_payment_id: order.paymentProviderPaymentId || null,
    });
    recordEvent("payment_attempt_cancel", {
      orderId: order.id,
      paymentId: data.payment?.id,
      providerPaymentId: data.payment?.provider_payment_id,
      provider: "mercado_pago",
    });
    return data.payment;
  }

  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.rpc("shopping_pagamento_cancelar_tentativa_rpc", {
    p_pagamento_id: order.paymentId,
  });
  if (error) throw error;

  const payment = normalizePayment(data);
  recordEvent("payment_attempt_cancel", { orderId: order.id, paymentId: payment?.id });
  return payment;
}

export async function createMercadoPagoPayment(orderId, method = "pix", cardPayload = null) {
  const data = await apiPaymentRequest(APP_CONFIG.paymentCreateEndpoint, {
    order_id: orderId,
    method,
    card_payload: cardPayload,
  });
  if (method === "pix") {
    console.info("[IAGO Payment] Pix provider response", {
      providerPaymentId: data.payment?.provider_payment_id ? "OK" : "VAZIO",
      qrCodeBase64: data.payment?.qr_code_base64 ? "OK" : "VAZIO",
      copiaCola: data.payment?.copia_cola ? "OK" : "VAZIO",
      expirationDate: data.payment?.expiration_date ? "OK" : "VAZIO",
      status: data.payment?.status || "VAZIO",
    });
  }
  recordEvent("payment_attempt_create", {
    orderId,
    paymentId: data.payment?.id,
    providerPaymentId: data.payment?.provider_payment_id,
    method,
    provider: "mercado_pago",
  });
  return data.payment;
}

export async function syncMercadoPagoPayment(payment) {
  const data = await apiPaymentRequest(APP_CONFIG.paymentSyncEndpoint, {
    payment_id: payment.id,
    provider_payment_id: payment.provider_payment_id || payment.providerPaymentId,
  });
  recordEvent("payment_provider_result", {
    paymentId: data.payment?.id,
    providerPaymentId: data.payment?.provider_payment_id,
    status: data.payment?.status,
    provider: "mercado_pago",
  });
  return data.payment;
}

export async function startPayment(orderId, method = "pix", paymentEngine = null, cardPayload = null) {
  if (isMercadoPagoEngine(paymentEngine)) {
    return createMercadoPagoPayment(orderId, method, cardPayload);
  }

  const payment = await createPaymentAttempt(orderId, method);
  await wait(getMockDelay(paymentEngine));
  return processPaymentAttempt(payment.id);
}

let mercadoPagoSdkPromise;

export function loadMercadoPagoSdk() {
  if (window.MercadoPago) return Promise.resolve(window.MercadoPago);
  if (!mercadoPagoSdkPromise) {
    mercadoPagoSdkPromise = new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = "https://sdk.mercadopago.com/js/v2";
      script.async = true;
      script.onload = () => resolve(window.MercadoPago);
      script.onerror = () => reject(new Error("Não foi possível carregar o SDK do Mercado Pago."));
      document.head.append(script);
    });
  }
  return mercadoPagoSdkPromise;
}

export async function mountMercadoPagoPaymentBrick({
  container,
  publicKey,
  amount,
  method,
  onSubmit,
  onError,
}) {
  if (!container || !publicKey) return null;
  const MercadoPago = await loadMercadoPagoSdk();
  const mp = new MercadoPago(publicKey, { locale: "pt-BR" });
  const bricksBuilder = mp.bricks();
  const excludedCardTypes = method === "cartao_debito"
    ? ["credit_card", "prepaid_card"]
    : ["debit_card", "prepaid_card"];

  return bricksBuilder.create("cardPayment", container.id, {
    initialization: {
      amount,
    },
    customization: {
      visual: {
        style: {
          theme: "dark",
          customVariables: {
            /* ==========================
              IDENTIDADE IAGO SHOPPING
            ========================== */

            baseColor: "#19ddda",
            baseColorFirstVariant: "#12bdbb",
            baseColorSecondVariant: "#0d8488",

            /* Feedback */

            errorColor: "#ff6b6b",
            successColor: "#22c55e",
            successSecondaryColor: "#0f3d33",
            secondarySuccessColor: "#0f3d33",

            /* Bordas */

            outlinePrimaryColor: "#19ddda",
            outlineSecondaryColor: "rgba(255,255,255,0.16)",

            /* Botões */

            buttonTextColor: "#031014",

            /* Fundo geral */

            formBackgroundColor: "#061a26",

            /* Inputs (somente funciona se o Brick suportar) */

            inputBackgroundColor: "#020b10",

            /* Texto */

            textPrimaryColor: "#368cadff",
            textSecondaryColor: "#708896",

            /* Focus */

            inputFocusedBoxShadow:
              "0 0 0 3px rgba(25,221,218,0.22)",

            inputErrorFocusedBoxShadow:
              "0 0 0 3px rgba(255,107,107,0.22)",

            /* Bordas */

            inputBorderWidth: "1px",
            inputFocusedBorderWidth: "1px",

            /* Espaçamento */

            inputVerticalPadding: "10px",
            inputHorizontalPadding: "12px",

            /* Raios */

            borderRadiusSmall: "8px",
            borderRadiusMedium: "10px",
            borderRadiusLarge: "12px",
            borderRadiusFull: "999px",

            /* Formulário */

            formPadding: "12px",
          },
        },
      },
      paymentMethods: {
        types: {
          excluded: excludedCardTypes,
        },
      },
    },
    callbacks: {
      onReady: () => {
        console.info("[IAGO Payment] Card Payment Brick ready", {
          method,
          publicKey: publicKey ? "OK" : "VAZIO",
          theme: "dark",
        });
        recordEvent("payment_brick_ready", { method });
      },
      onSubmit: (formData) => onSubmit(formData),
      onError: (error) => {
        console.warn(error);
        if (onError) onError(error);
      },
    },
  });
}
