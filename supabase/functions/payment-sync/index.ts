import { assertMethod, firstRow, HttpError, jsonResponse, readJsonBody, withCors } from "../_shared/response.ts";
import { callRpc, userSupabaseClient } from "../_shared/supabase.ts";
import { getMercadoPagoPayment, isMercadoPagoProvider } from "../_shared/mercado_pago.ts";

Deno.serve((request) => withCors(request, async () => {
  assertMethod(request, ["POST"]);
  if (!isMercadoPagoProvider()) {
    throw new HttpError(400, "Provider ativo não usa sincronização externa.");
  }

  const payload = await readJsonBody(request);
  const paymentId = String(payload.payment_id || "");
  const providerPaymentId = String(payload.provider_payment_id || "");
  if (!paymentId) throw new HttpError(400, "Pagamento obrigatório para sincronização.");
  if (!providerPaymentId) throw new HttpError(400, "Pagamento ainda não possui ID no provider.");

  const { supabase } = await userSupabaseClient(request);
  const providerResult = await getMercadoPagoPayment(providerPaymentId);
  const payment = firstRow(await callRpc(supabase, "shopping_pagamento_mercado_pago_sincronizar_consulta", {
    p_pagamento_id: paymentId,
    p_provider_status: providerResult.provider_status,
    p_provider_payload: providerResult.provider_payload,
    p_response_headers: providerResult.response_headers,
    p_http_status: providerResult.http_status,
    p_erro_tecnico: providerResult.erro_tecnico,
    p_erro_negocio: providerResult.erro_negocio,
  }));

  return jsonResponse(request, {
    payment,
    provider_payload: providerResult.provider_payload,
  });
}));
