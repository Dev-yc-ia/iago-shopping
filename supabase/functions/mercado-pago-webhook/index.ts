import { assertMethod, jsonResponse, readJsonBody, withCors } from "../_shared/response.ts";
import { adminSupabaseClient, callRpc } from "../_shared/supabase.ts";
import { getMercadoPagoPayment, verifyMercadoPagoWebhook } from "../_shared/mercado_pago.ts";

Deno.serve((request) => withCors(request, async () => {
  assertMethod(request, ["POST"]);

  const payload = await readJsonBody(request);
  const providerPaymentId = await verifyMercadoPagoWebhook(request, payload);
  const providerResult = await getMercadoPagoPayment(providerPaymentId);
  const headers = Object.fromEntries(
    [...request.headers.entries()].filter(([key]) => (
      key.startsWith("x-") || key.startsWith("content-") || key === "user-agent"
    )),
  );

  await callRpc(adminSupabaseClient(), "shopping_pagamento_mercado_pago_processar_webhook", {
    p_provider_payment_id: providerPaymentId,
    p_provider_status: providerResult.provider_status,
    p_payload_bruto: payload,
    p_payload_tratado: providerResult.provider_payload,
    p_headers: headers,
  });

  return jsonResponse(request, {
    received: true,
    provider_payment_id: providerPaymentId,
    status: providerResult.provider_status,
  });
}));
