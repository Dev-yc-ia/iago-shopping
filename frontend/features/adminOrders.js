import { getSupabaseClient } from "./auth.js";
import { formatCurrency } from "../utils/format.js";
import {
  PAYMENT_METHOD_LABELS,
  PAYMENT_STATUS_LABELS,
  cancelPaymentAttempt,
  getPaymentEngineMetadata,
} from "./payments.js";

const ORDER_STATUS_LABELS = {
  pendente_pagamento: "Pendente de pagamento",
  cancelado: "Cancelado",
};

const DELIVERY_STATUS_LABELS = {
  aguardando_parceiro: "Parceiro preparando",
  enviado: "Envio confirmado",
  entregue_pessoalmente: "Entrega pessoal confirmada",
  recebido_cliente: "Recebido pelo cliente",
  cancelado: "Entrega cancelada",
};

const PAYOUT_STATUS_LABELS = {
  bloqueado: "Repasse bloqueado",
  elegivel: "Repasse elegível",
  pago: "Repasse pago",
};

function formatDate(value) {
  if (!value) return "Data não informada";
  return new Intl.DateTimeFormat("pt-BR", {
    dateStyle: "short",
    timeStyle: "short",
  }).format(new Date(value));
}

function formatDateOnly(value) {
  if (!value) return "";
  return new Intl.DateTimeFormat("pt-BR", { dateStyle: "short" }).format(new Date(value));
}

function deliveryWindow(delivery) {
  if (!delivery?.previsao_inicio || !delivery?.previsao_fim) return "Previsão não informada";
  return `Previsão entre ${formatDateOnly(delivery.previsao_inicio)} e ${formatDateOnly(delivery.previsao_fim)}`;
}

function normalizeAdminOrder(order) {
  const items = Array.isArray(order.itens) ? order.itens : [];
  const internalNumber = order.numero;
  return {
    id: order.id,
    internalNumber,
    number: order.numero_cliente || internalNumber,
    status: order.status,
    paymentStatus: order.pagamento_status || "pendente",
    paymentId: order.pagamento_id || null,
    paymentProvider: order.pagamento_provedor || "",
    paymentProviderMode: order.pagamento_provider_mode || "",
    paymentProviderPaymentId: order.pagamento_provider_payment_id || "",
    paymentProviderStatus: order.pagamento_provider_status || "",
    paymentMethod: order.pagamento_metodo || "pix",
    customerName: order.cliente_nome || "Cliente",
    customerEmail: order.cliente_email || "E-mail não informado",
    total: Number(order.total || 0),
    canceledAt: order.cancelado_em || "",
    canceledByType: order.cancelado_por_tipo || "",
    cancellationReason: order.motivo_cancelamento || "",
    fulfillmentStatus: order.fulfillment_status || "pendente_pagamento",
    deliveries: Array.isArray(order.entregas) ? order.entregas : [],
    createdAt: order.criado_em,
    items,
  };
}

function paymentProviderLabel(provider) {
  if (provider === "mercado_pago") return "Mercado Pago";
  if (provider === "mock") return "Provider histórico";
  return provider || "Provider não informado";
}

function normalizePartnerOrder(order) {
  const items = Array.isArray(order.itens) ? order.itens : [];
  const internalNumber = order.numero;
  return {
    deliveryId: order.entrega_id,
    id: order.pedido_id,
    internalNumber,
    number: order.numero_cliente || internalNumber,
    customerName: order.cliente_nome || "Cliente",
    customerEmail: order.cliente_email || "E-mail não informado",
    address: order.endereco_entrega_snapshot || null,
    paymentStatus: order.pagamento_status || "pendente",
    deliveryStatus: order.entrega_status || "aguardando_parceiro",
    fulfillmentMethod: order.metodo_cumprimento || "",
    payoutStatus: order.repasse_status || "bloqueado",
    forecastStart: order.previsao_inicio || "",
    forecastEnd: order.previsao_fim || "",
    partnerConfirmedAt: order.parceiro_confirmado_em || "",
    customerConfirmedAt: order.cliente_confirmado_em || "",
    payoutTotal: Number(order.valor_repasse_total || 0),
    createdAt: order.criado_em,
    updatedAt: order.atualizado_em,
    items: items.map((item) => ({
      id: item.item_id,
      variationName: item.variacao_nome || "",
      sku: item.sku,
      name: item.nome,
      brand: item.marca,
      quantity: Number(item.quantidade || 0),
      payoutTotal: Number(item.valor_repasse_total_snapshot || 0),
    })),
  };
}

function isFinalPaymentStatus(status) {
  return ["aprovado", "recusado", "expirado", "cancelado"].includes(status);
}

function hasActivePaymentAttempt(order) {
  return Boolean(order?.paymentId) && !isFinalPaymentStatus(order.paymentStatus);
}

function canCancelAdminOrder(order, isMaster) {
  return isMaster && order.status !== "cancelado" && order.paymentStatus !== "aprovado";
}

async function cancelAdminOrder(order, motivo, paymentEngine) {
  if (hasActivePaymentAttempt(order)) {
    await cancelPaymentAttempt(order, paymentEngine);
  }

  const supabase = await getSupabaseClient();
  const { error } = await supabase.rpc("shopping_admin_cancelar_pedido", {
    p_pedido_id: order.id,
    p_motivo: motivo,
  });
  if (error) throw error;
}

async function loadAdminOrders() {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.rpc("shopping_admin_listar_pedidos");
  if (error) throw error;
  return (data || []).map(normalizeAdminOrder);
}

async function loadPartnerOrders() {
  const supabase = await getSupabaseClient();
  const { error: reconcileError } = await supabase.rpc("shopping_parceiro_reconciliar_pedidos_pagos_legados");
  if (reconcileError) throw reconcileError;

  const { data, error } = await supabase.rpc("shopping_parceiro_listar_pedidos");
  if (error) throw error;
  return (data || []).map(normalizePartnerOrder);
}

async function confirmPartnerDelivery(deliveryId, method) {
  const supabase = await getSupabaseClient();
  const { error } = await supabase.rpc("shopping_parceiro_confirmar_entrega", {
    p_entrega_id: deliveryId,
    p_metodo: method,
  });
  if (error) throw error;
}

async function loadAdminPayments() {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.rpc("shopping_admin_listar_pagamentos");
  if (error) throw error;
  return data || [];
}

function addressText(address) {
  if (!address) return "Endereço de entrega não informado no pedido.";
  const parts = [
    address.nome_destinatario,
    [address.logradouro, address.numero].filter(Boolean).join(", "),
    address.complemento,
    address.bairro,
    [address.cidade, address.uf].filter(Boolean).join(" - "),
    address.cep ? `CEP ${address.cep}` : "",
    address.referencia,
  ].filter(Boolean);
  return parts.join(" | ") || "Endereço de entrega não informado no pedido.";
}

function renderDeliveryLine(delivery) {
  const line = document.createElement("p");
  line.className = "extension-note";
  line.textContent = [
    delivery.parceiro_nome || "Parceiro",
    DELIVERY_STATUS_LABELS[delivery.status] || delivery.status,
    PAYOUT_STATUS_LABELS[delivery.repasse_status] || delivery.repasse_status,
    formatCurrency(delivery.valor_repasse_total),
    deliveryWindow(delivery),
  ].filter(Boolean).join(" | ");
  return line;
}

function renderAdminOrder(order, handlers) {
  const card = document.createElement("article");
  card.className = "admin-card order-admin-card";

  const status = document.createElement("span");
  status.className = "card-kicker";
  status.textContent = order.status === "cancelado"
    ? "Pedido cancelado"
    : PAYMENT_STATUS_LABELS[order.paymentStatus] || ORDER_STATUS_LABELS[order.status] || order.status;

  const title = document.createElement("h2");
  title.textContent = `Pedido #${order.number}`;

  const internalRef = document.createElement("p");
  internalRef.textContent = `Ref. interna #${order.internalNumber}`;

  const customer = document.createElement("p");
  customer.textContent = `${order.customerName} | ${order.customerEmail}`;

  const date = document.createElement("p");
  date.textContent = formatDate(order.createdAt);

  const total = document.createElement("strong");
  total.textContent = formatCurrency(order.total);

  const items = document.createElement("p");
  items.textContent = `${order.items.length} item${order.items.length === 1 ? "" : "s"} no pedido.`;

  const payment = document.createElement("p");
  payment.textContent = `${paymentProviderLabel(order.paymentProvider)}${order.paymentProviderMode ? `/${order.paymentProviderMode}` : ""} | ${PAYMENT_METHOD_LABELS[order.paymentMethod] || order.paymentMethod}`;

  const note = document.createElement("p");
  note.className = "extension-note";
  note.textContent = order.status === "cancelado"
    ? `${order.cancellationReason || "Pedido cancelado."}${order.canceledAt ? ` | ${formatDate(order.canceledAt)}` : ""}`
    : `Entrega: ${order.fulfillmentStatus === "concluido" ? "concluída" : "em andamento"}.`;

  card.append(status, title, internalRef, customer, date, total, items, payment, note);
  order.deliveries.forEach((delivery) => card.append(renderDeliveryLine(delivery)));
  if (canCancelAdminOrder(order, handlers.isMaster)) {
    const cancelButton = document.createElement("button");
    cancelButton.className = "button secondary order-cancel-button";
    cancelButton.type = "button";
    cancelButton.textContent = "Cancelar pedido";
    cancelButton.disabled = handlers.processingOrderId === order.id;
    cancelButton.addEventListener("click", () => handlers.onCancelOrder(order, cancelButton));
    card.append(cancelButton);
  }
  return card;
}

function canPartnerAct(order) {
  return order.paymentStatus === "aprovado" && order.deliveryStatus === "aguardando_parceiro";
}

function renderPartnerOrder(order, handlers) {
  const card = document.createElement("article");
  card.className = "admin-card order-admin-card";

  const status = document.createElement("span");
  status.className = "card-kicker";
  status.textContent = DELIVERY_STATUS_LABELS[order.deliveryStatus] || order.deliveryStatus;

  const title = document.createElement("h2");
  title.textContent = `Pedido #${order.number}`;

  const customer = document.createElement("p");
  customer.textContent = `${order.customerName} | ${order.customerEmail}`;

  const address = document.createElement("p");
  address.textContent = addressText(order.address);

  const forecast = document.createElement("p");
  forecast.className = "extension-note";
  forecast.textContent = `${deliveryWindow({ previsao_inicio: order.forecastStart, previsao_fim: order.forecastEnd })} | ${PAYOUT_STATUS_LABELS[order.payoutStatus] || order.payoutStatus}`;

  const payout = document.createElement("strong");
  payout.textContent = `Repasse previsto: ${formatCurrency(order.payoutTotal)}`;

  const items = document.createElement("p");
  items.textContent = order.items.map((item) => {
    const variation = item.variationName && item.variationName !== "Padrao" ? ` (${item.variationName})` : "";
    return `${item.quantity}x ${item.name}${variation}`;
  }).join(" | ") || "Itens não encontrados para este parceiro.";

  card.append(status, title, customer, address, forecast, payout, items);

  if (canPartnerAct(order)) {
    const actions = document.createElement("div");
    actions.className = "checkout-actions";

    const shipButton = document.createElement("button");
    shipButton.className = "button primary";
    shipButton.type = "button";
    shipButton.textContent = "Confirmar envio";
    shipButton.disabled = handlers.processingDeliveryId === order.deliveryId;
    shipButton.addEventListener("click", () => handlers.onConfirmDelivery(order, "envio", shipButton));

    const personalButton = document.createElement("button");
    personalButton.className = "button secondary";
    personalButton.type = "button";
    personalButton.textContent = "Confirmar entrega pessoal";
    personalButton.disabled = handlers.processingDeliveryId === order.deliveryId;
    personalButton.addEventListener("click", () => handlers.onConfirmDelivery(order, "entrega_pessoal", personalButton));

    actions.append(shipButton, personalButton);
    card.append(actions);
  }

  return card;
}

function renderAdminPayment(payment) {
  const card = document.createElement("article");
  card.className = "admin-card payment-admin-card";

  const status = document.createElement("span");
  status.className = "card-kicker";
  status.textContent = PAYMENT_STATUS_LABELS[payment.status] || payment.status;

  const title = document.createElement("h2");
  title.textContent = `Pagamento #${payment.pedido_numero}`;

  const customer = document.createElement("p");
  customer.textContent = `${payment.cliente_nome || "Cliente"} | ${payment.cliente_email || "E-mail não informado"}`;

  const method = document.createElement("p");
  method.textContent = `${paymentProviderLabel(payment.provedor)}${payment.provider_mode ? `/${payment.provider_mode}` : ""} | ${PAYMENT_METHOD_LABELS[payment.metodo] || payment.metodo}`;

  const providerTrace = document.createElement("p");
  providerTrace.textContent = payment.provider_payment_id
    ? `Provider ID ${payment.provider_payment_id} | ${payment.provider_status || "sem status externo"}`
    : "Provider externo ainda não retornou ID.";

  const total = document.createElement("strong");
  total.textContent = formatCurrency(payment.valor);

  const trace = document.createElement("p");
  trace.textContent = `${payment.eventos} evento${payment.eventos === 1 ? "" : "s"} | ${payment.emails} notificaç${payment.emails === 1 ? "ão" : "ões"} operacional${payment.emails === 1 ? "" : "is"}`;

  const error = document.createElement("p");
  error.className = "extension-note";
  error.textContent = payment.erro_mensagem || "Sem erro registrado pelo provider.";

  card.append(status, title, customer, method, providerTrace, total, trace, error);
  return card;
}

export async function initAdminOrders({ role = "", isMaster = false, module = "orders" } = {}) {
  const isDeliveriesModule = module === "deliveries";
  const container = document.querySelector(isDeliveriesModule ? "[data-admin-deliveries]" : "[data-admin-orders]");
  const feedback = document.querySelector(isDeliveriesModule ? "[data-admin-deliveries-feedback]" : "[data-admin-orders-feedback]");
  if (!container) return;
  let paymentEngine = null;
  let processingOrderId = "";
  let processingDeliveryId = "";

  async function onCancelOrder(order, button) {
    const motivo = window.prompt("Motivo do cancelamento:");
    if (!motivo || !motivo.trim()) {
      window.alert("Informe o motivo para cancelar como master.");
      return;
    }

    processingOrderId = order.id;
    button.disabled = true;
    button.textContent = "Cancelando...";
    try {
      paymentEngine = paymentEngine || await getPaymentEngineMetadata();
      await cancelAdminOrder(order, motivo.trim(), paymentEngine);
      processingOrderId = "";
      await refresh();
    } catch (error) {
      window.alert(error.message);
      processingOrderId = "";
      await refresh();
    } finally {
      processingOrderId = "";
    }
  }

  async function refresh() {
    if (role === "parceiro") {
      const orders = await loadPartnerOrders();
      if (feedback) {
        feedback.textContent = `${orders.length} entrega${orders.length === 1 ? "" : "s"} em acompanhamento.`;
      }
      if (!orders.length) {
        const empty = document.createElement("div");
        empty.className = "empty-state";
        empty.textContent = isDeliveriesModule
          ? "Nenhuma entrega dos seus produtos por enquanto."
          : "Nenhum pedido pago dos seus produtos por enquanto.";
        container.replaceChildren(empty);
        return;
      }

      container.replaceChildren(...orders.map((order) => renderPartnerOrder(order, {
        processingDeliveryId,
        onConfirmDelivery,
      })));
      return;
    }

    const orders = await loadAdminOrders();
    if (feedback) {
      feedback.textContent = isDeliveriesModule
        ? `${orders.length} pedido${orders.length === 1 ? "" : "s"} com entrega mapeada${orders.length === 1 ? "" : "s"}.`
        : `${orders.length} pedido${orders.length === 1 ? "" : "s"} recebido${orders.length === 1 ? "" : "s"}.`;
    }

    if (!orders.length) {
      const empty = document.createElement("div");
      empty.className = "empty-state";
      empty.textContent = "Nenhum pedido recebido até agora.";
      container.replaceChildren(empty);
      return;
    }

    container.replaceChildren(...orders.map((order) => renderAdminOrder(order, {
      isMaster,
      processingOrderId,
      onCancelOrder,
    })));
  }

  async function onConfirmDelivery(order, method, button) {
    const message = method === "entrega_pessoal"
      ? "Confirmar que você realizou a entrega pessoal deste pedido?"
      : "Confirmar que este pedido foi enviado ao cliente?";
    if (!window.confirm(message)) return;

    processingDeliveryId = order.deliveryId;
    button.disabled = true;
    button.textContent = "Confirmando...";
    try {
      await confirmPartnerDelivery(order.deliveryId, method);
      processingDeliveryId = "";
      await refresh();
    } catch (error) {
      window.alert(error.message);
      processingDeliveryId = "";
      await refresh();
    }
  }

  try {
    await refresh();
  } catch (error) {
    if (feedback) feedback.textContent = error.message;
    container.replaceChildren();
  }
}

export async function initAdminPayments() {
  const container = document.querySelector("[data-admin-payments]");
  const feedback = document.querySelector("[data-admin-payments-feedback]");
  if (!container) return;

  try {
    const payments = (await loadAdminPayments()).filter((payment) => payment.provedor !== "mock");
    if (feedback) {
      feedback.textContent = `${payments.length} pagamento${payments.length === 1 ? "" : "s"} real${payments.length === 1 ? "" : "is"} encontrado${payments.length === 1 ? "" : "s"}.`;
    }

    if (!payments.length) {
      const empty = document.createElement("div");
      empty.className = "empty-state";
      empty.textContent = "Nenhum pagamento real encontrado.";
      container.replaceChildren(empty);
      return;
    }

    container.replaceChildren(...payments.map(renderAdminPayment));
  } catch (error) {
    if (feedback) feedback.textContent = error.message;
    container.replaceChildren();
  }
}
