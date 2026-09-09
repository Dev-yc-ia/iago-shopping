import { assertMethod, firstRow, HttpError, jsonResponse, readJsonBody, withCors } from "../_shared/response.ts";
import { callRpc, userSupabaseClient } from "../_shared/supabase.ts";
import { createMercadoPagoPayment, isMercadoPagoProvider } from "../_shared/mercado_pago.ts";

Deno.serve((request) => withCors(request, async () => {
  assertMethod(request, ["POST"]);
  if (!isMercadoPagoProvider()) {
    throw new HttpError(400, "Provider ativo não usa checkout externo.");
  }

  const payload = await readJsonBody(request);
  const orderId = String(payload.order_id || "");
  const method = String(payload.method || "pix");
  const cardPayload = payload.card_payload && typeof payload.card_payload === "object"
    ? payload.card_payload as Record<string, unknown>
    : null;

  if (!orderId) throw new HttpError(400, "Pedido obrigatório para checkout.");

  const { supabase } = await userSupabaseClient(request);
  const context = firstRow(await callRpc(supabase, "shopping_pagamento_checkout_context", {
    p_pedido_id: orderId,
  }));
  if (!Object.keys(context).length) {
    throw new HttpError(404, "Pedido não encontrado para checkout.");
  }

  const providerResult = await createMercadoPagoPayment(context, method, cardPayload);
  let payment = firstRow(await callRpc(supabase, "shopping_pagamento_mercado_pago_registrar_checkout", {
    p_pedido_id: orderId,
    p_metodo: method,
    p_provider_mode: providerResult.provider_mode,
    p_provider_payment_id: providerResult.provider_payment_id,
    p_provider_transaction_id: providerResult.provider_transaction_id,
    p_qr_code_base64: providerResult.qr_code_base64,
    p_qr_code_url: providerResult.qr_code_url,
    p_copia_cola: providerResult.copia_cola,
    p_external_reference: providerResult.external_reference,
    p_payment_url: providerResult.payment_url,
    p_expiration_date: providerResult.expiration_date,
    p_provider_status: providerResult.provider_status,
    p_idempotency_key: providerResult.idempotency_key,
    p_request_payload: providerResult.request_payload,
    p_response_payload: providerResult.response_payload,
    p_response_headers: providerResult.response_headers,
    p_tempo_resposta_ms: providerResult.tempo_resposta_ms,
    p_http_status: providerResult.http_status,
    p_erro_tecnico: providerResult.erro_tecnico,
    p_erro_negocio: providerResult.erro_negocio,
  }));

  if (providerResult.provider_status) {
    payment = firstRow(await callRpc(supabase, "shopping_pagamento_mercado_pago_sincronizar_consulta", {
      p_pagamento_id: payment.id,
      p_provider_status: providerResult.provider_status,
      p_provider_payload: providerResult.response_payload,
      p_response_headers: providerResult.response_headers,
      p_http_status: providerResult.http_status,
      p_erro_tecnico: providerResult.erro_tecnico,
      p_erro_negocio: providerResult.erro_negocio,
    }));
  }

  return jsonResponse(request, {
    payment,
    provider_payload: providerResult.response_payload,
  });
}));
