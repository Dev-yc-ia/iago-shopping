import { assertMethod, firstRow, HttpError, jsonResponse, readJsonBody, withCors } from "../_shared/response.ts";
import { callRpc, userSupabaseClient } from "../_shared/supabase.ts";
import { cancelMercadoPagoPayment, isMercadoPagoProvider } from "../_shared/mercado_pago.ts";

Deno.serve((request) => withCors(request, async () => {
  assertMethod(request, ["POST"]);

  const payload = await readJsonBody(request);
  const paymentId = String(payload.payment_id || "");
  const providerPaymentId = String(payload.provider_payment_id || "");
  if (!paymentId) throw new HttpError(400, "Pagamento obrigatório para cancelamento.");

  const { supabase } = await userSupabaseClient(request);
  let providerResult: Record<string, unknown> | null = null;

  if (isMercadoPagoProvider() && providerPaymentId) {
    providerResult = await cancelMercadoPagoPayment(providerPaymentId);
    const providerStatus = String(providerResult.provider_status || "").toLowerCase();

    if (providerStatus && !["cancelled", "canceled"].includes(providerStatus)) {
      await callRpc(supabase, "shopping_pagamento_mercado_pago_sincronizar_consulta", {
        p_pagamento_id: paymentId,
        p_provider_status: providerResult.provider_status,
        p_provider_payload: providerResult.provider_payload,
        p_response_headers: providerResult.response_headers,
        p_http_status: providerResult.http_status,
        p_erro_tecnico: providerResult.erro_tecnico,
        p_erro_negocio: providerResult.erro_negocio,
      });

      throw new HttpError(
        409,
        `Mercado Pago não confirmou o cancelamento. Status atual do provider: ${providerStatus || "indefinido"}.`,
      );
    }
  }

  const payment = firstRow(await callRpc(supabase, "shopping_pagamento_cancelar_tentativa_rpc", {
    p_pagamento_id: paymentId,
    p_payload: {
      provider: isMercadoPagoProvider() ? "mercado_pago" : "mock",
      provider_payment_id: providerPaymentId || null,
      provider_cancel_response: providerResult || {},
    },
  }));

  return jsonResponse(request, {
    payment,
    provider_payload: providerResult?.provider_payload || null,
  });
}));
