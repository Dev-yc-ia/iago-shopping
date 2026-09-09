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

function formatDate(value) {
  if (!value) return "Data não informada";
  return new Intl.DateTimeFormat("pt-BR", {
    dateStyle: "short",
    timeStyle: "short",
  }).format(new Date(value));
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
    paymentProvider: order.pagamento_provedor || "mock",
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
    createdAt: order.criado_em,
    items,
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

async function loadAdminPayments() {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.rpc("shopping_admin_listar_pagamentos");
  if (error) throw error;
  return data || [];
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
  payment.textContent = `${order.paymentProvider}${order.paymentProviderMode ? `/${order.paymentProviderMode}` : ""} | ${PAYMENT_METHOD_LABELS[order.paymentMethod] || order.paymentMethod}`;

  const note = document.createElement("p");
  note.className = "extension-note";
  note.textContent = order.status === "cancelado"
    ? `${order.cancellationReason || "Pedido cancelado."}${order.canceledAt ? ` | ${formatDate(order.canceledAt)}` : ""}`
    : "Pagamento acompanhado pelo Payment Engine.";

  card.append(status, title, internalRef, customer, date, total, items, payment, note);
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
  method.textContent = `${payment.provedor}${payment.provider_mode ? `/${payment.provider_mode}` : ""} | ${PAYMENT_METHOD_LABELS[payment.metodo] || payment.metodo}`;

  const providerTrace = document.createElement("p");
  providerTrace.textContent = payment.provider_payment_id
    ? `Provider ID ${payment.provider_payment_id} | ${payment.provider_status || "sem status externo"}`
    : "Provider externo ainda não retornou ID.";

  const total = document.createElement("strong");
  total.textContent = formatCurrency(payment.valor);

  const trace = document.createElement("p");
  trace.textContent = `${payment.eventos} evento${payment.eventos === 1 ? "" : "s"} | ${payment.emails} e-mail${payment.emails === 1 ? "" : "s"} simulado${payment.emails === 1 ? "" : "s"}`;

  const error = document.createElement("p");
  error.className = "extension-note";
  error.textContent = payment.erro_mensagem || "Sem erro registrado pelo provider.";

  card.append(status, title, customer, method, providerTrace, total, trace, error);
  return card;
}

export async function initAdminOrders({ isMaster = false } = {}) {
  const container = document.querySelector("[data-admin-orders]");
  const feedback = document.querySelector("[data-admin-orders-feedback]");
  const paymentsContainer = document.querySelector("[data-admin-payments]");
  const paymentsFeedback = document.querySelector("[data-admin-payments-feedback]");
  if (!container) return;
  let paymentEngine = null;
  let processingOrderId = "";

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
    const [orders, payments, engine] = await Promise.all([
      loadAdminOrders(),
      loadAdminPayments(),
      getPaymentEngineMetadata(),
    ]);
    paymentEngine = engine;
    if (feedback) {
      feedback.textContent = `${orders.length} pedido${orders.length === 1 ? "" : "s"} recebido${orders.length === 1 ? "" : "s"}.`;
    }
    if (paymentsFeedback) {
      paymentsFeedback.textContent = `${payments.length} tentativa${payments.length === 1 ? "" : "s"} de pagamento.`;
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
    if (paymentsContainer) {
      if (!payments.length) {
        const emptyPayments = document.createElement("div");
        emptyPayments.className = "empty-state";
        emptyPayments.textContent = "Nenhum pagamento simulado até agora.";
        paymentsContainer.replaceChildren(emptyPayments);
      } else {
        paymentsContainer.replaceChildren(...payments.map(renderAdminPayment));
      }
    }
  }

  try {
    await refresh();
  } catch (error) {
    if (feedback) feedback.textContent = error.message;
    if (paymentsFeedback) paymentsFeedback.textContent = error.message;
    container.replaceChildren();
    paymentsContainer?.replaceChildren();
  }
}
