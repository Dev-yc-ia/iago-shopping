import { assertMethod, jsonResponse, withCors } from "../_shared/response.ts";
import { mercadoPagoEngineMetadata } from "../_shared/mercado_pago.ts";

Deno.serve((request) => withCors(request, () => {
  assertMethod(request, ["GET", "POST"]);
  return jsonResponse(request, mercadoPagoEngineMetadata());
}));
