import { getSupabaseClient } from "./auth.js";
import { createProductImage } from "../ui/productImage.js";
import { recordEvent } from "../utils/analytics.js";
import { formatCurrency } from "../utils/format.js";
import {
  PAYMENT_STATUS_LABELS,
  cancelPaymentAttempt,
  getPaymentEngineMetadata,
} from "./payments.js";

const ORDER_STATUS_LABELS = {
  pendente_pagamento: "Pendente de pagamento",
  cancelado: "Cancelado",
};

function currentRelativeUrl() {
  return `/pedidos/${window.location.search}`;
}

function redirectToOrdersLogin() {
  const redirect = encodeURIComponent(currentRelativeUrl());
  window.location.href = `/login/?aviso=pedidos&redirect=${redirect}`;
}

async function getAuthenticatedOrdersClient() {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.auth.getSession();
  if (error) throw error;

  if (!data.session?.user) {
    redirectToOrdersLogin();
    return null;
  }

  return supabase;
}

function formatDate(value) {
  if (!value) return "Data não informada";
  return new Intl.DateTimeFormat("pt-BR", {
    dateStyle: "short",
    timeStyle: "short",
  }).format(new Date(value));
}

function normalizeOrder(order) {
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
    paymentMethod: order.pagamento_metodo || "pix",
    paymentErrorCode: order.pagamento_erro_codigo || "",
    paymentErrorMessage: order.pagamento_erro_mensagem || "",
    paymentProviderMode: order.pagamento_provider_mode || "",
    paymentProviderPaymentId: order.pagamento_provider_payment_id || "",
    paymentProviderPreferenceId: order.pagamento_provider_preference_id || "",
    paymentProviderTransactionId: order.pagamento_provider_transaction_id || "",
    paymentQrCodeBase64: order.pagamento_qr_code_base64 || "",
    paymentQrCodeUrl: order.pagamento_qr_code_url || "",
    paymentCopyPaste: order.pagamento_copia_cola || "",
    paymentExternalReference: order.pagamento_external_reference || "",
    paymentUrl: order.pagamento_payment_url || "",
    paymentExpirationDate: order.pagamento_expiration_date || "",
    paymentProviderStatus: order.pagamento_provider_status || "",
    paymentLastSync: order.pagamento_ultima_sincronizacao || "",
    total: Number(order.total || 0),
    currency: order.moeda || "BRL",
    canceledAt: order.cancelado_em || "",
    canceledByType: order.cancelado_por_tipo || "",
    cancellationReason: order.motivo_cancelamento || "",
    createdAt: order.criado_em,
    items: items.map((item) => ({
      id: item.item_id,
      productId: item.produto_id,
      variationId: item.variacao_id || null,
      variationName: item.variacao_nome || "",
      sku: item.sku,
      name: item.nome,
      brand: item.marca,
      category: item.categoria,
      imageUrl: item.imagem_url || "",
      quantity: Number(item.quantidade || 0),
      unitPrice: Number(item.preco_unitario || 0),
      subtotal: Number(item.subtotal || 0),
    })),
  };
}

function isFinalPaymentStatus(status) {
  return ["aprovado", "recusado", "expirado", "cancelado"].includes(status);
}

function hasActivePaymentAttempt(order) {
  return Boolean(order?.paymentId) && !isFinalPaymentStatus(order.paymentStatus);
}

function canCancelOrder(order) {
  return order.status !== "cancelado" && order.paymentStatus !== "aprovado";
}

async function cancelCustomerOrder(order, paymentEngine) {
  if (!window.confirm("Tem certeza que deseja cancelar este pedido?")) return false;

  if (hasActivePaymentAttempt(order)) {
    await cancelPaymentAttempt(order, paymentEngine);
  }

  const supabase = await getAuthenticatedOrdersClient();
  if (!supabase) return false;

  const { error } = await supabase.rpc("shopping_pedido_cliente_cancelar", {
    p_pedido_id: order.id,
    p_motivo: "Cancelado pelo cliente",
  });
  if (error) throw error;

  recordEvent("order_cancel_customer", { orderId: order.id, paymentId: order.paymentId });
  return true;
}

async function loadOrders() {
  const supabase = await getAuthenticatedOrdersClient();
  if (!supabase) return [];

  const { data, error } = await supabase.rpc("shopping_pedidos_cliente_listar");
  if (error) throw error;
  return (data || []).map(normalizeOrder);
}

function renderOrderItem(item) {
  const row = document.createElement("div");
  row.className = "order-item";

  const image = createProductImage({
    src: item.imageUrl,
    alt: item.name,
    fallbackText: item.category,
    variant: "cart-thumb",
  });

  const content = document.createElement("div");
  content.className = "order-item-content";

  const brand = document.createElement("span");
  brand.className = "card-kicker";
  brand.textContent = item.brand;

  const title = document.createElement("strong");
  title.textContent = item.name;

  const meta = document.createElement("span");
  const variationText = item.variationName && item.variationName !== "Padrao"
    ? ` | Variação: ${item.variationName}`
    : "";
  meta.textContent = `${item.sku}${variationText} | ${item.quantity} un.`;

  content.append(brand, title, meta);

  const subtotal = document.createElement("strong");
  subtotal.textContent = formatCurrency(item.subtotal);

  row.append(image, content, subtotal);
  return row;
}

function paymentStatusText(order, isProcessing = false) {
  if (isProcessing) return "Processando pagamento";
  if (order.status === "cancelado") return "Pedido cancelado";
  if (order.paymentErrorCode === "mock_timeout") return "Tempo esgotado no processamento";
  if (order.paymentStatus === "expirado" && order.paymentMethod === "pix") return "PIX expirado";
  return PAYMENT_STATUS_LABELS[order.paymentStatus] || order.paymentStatus;
}

function paymentMessageText(order, isProcessing = false) {
  if (isProcessing) {
    return "Payment Engine processando a tentativa. O pedido será atualizado automaticamente.";
  }

  if (order.status === "cancelado") {
    const date = order.canceledAt ? ` em ${formatDate(order.canceledAt)}` : "";
    const actor = order.canceledByType === "master" ? "pelo master" : "pelo cliente";
    return `Pedido cancelado ${actor}${date}.`;
  }

  if (order.paymentStatus === "aprovado") {
    return "Pagamento aprovado. O estoque foi confirmado automaticamente.";
  }

  if (order.paymentStatus === "recusado") {
    return "Pagamento recusado pelo provider. Você pode tentar novamente com outro método.";
  }

  if (order.paymentStatus === "expirado" && order.paymentMethod === "pix") {
    return "PIX expirado. Gere uma nova tentativa para continuar.";
  }

  if (order.paymentStatus === "expirado") {
    return "Pagamento expirado. Gere uma nova tentativa para continuar.";
  }

  if (order.paymentErrorCode === "mock_timeout") {
    return "O provider não respondeu dentro do tempo configurado. Você pode tentar novamente.";
  }

  if (order.paymentId) {
    return "Pagamento aguardando confirmação automática do provider.";
  }

  return "Escolha a forma de pagamento para iniciar.";
}

function renderPaymentSummary(order) {
  const panel = document.createElement("div");
  panel.className = "payment-panel payment-panel--summary";

  const title = document.createElement("strong");
  title.textContent = `Pagamento: ${paymentStatusText(order)}`;

  const message = document.createElement("p");
  message.className = "payment-status-message";
  message.textContent = paymentMessageText(order);

  panel.append(title, message);
  return panel;
}

function renderCancellationDetails(order) {
  if (order.status !== "cancelado") return null;

  const note = document.createElement("p");
  note.className = "extension-note";
  note.textContent = order.cancellationReason || "Pedido cancelado.";
  return note;
}

function renderOrderCard(order, highlightedId, handlers) {
  const card = document.createElement("article");
  card.className = "order-card";
  card.classList.toggle("is-highlighted", order.id === highlightedId);

  const header = document.createElement("div");
  header.className = "order-card-header";

  const titleWrap = document.createElement("div");
  const status = document.createElement("span");
  status.className = "card-kicker";
  status.textContent = paymentStatusText(order) || ORDER_STATUS_LABELS[order.status] || order.status;

  const title = document.createElement("h2");
  title.textContent = `Pedido #${order.number}`;

  const date = document.createElement("p");
  date.textContent = formatDate(order.createdAt);

  titleWrap.append(status, title, date);

  const total = document.createElement("strong");
  total.textContent = formatCurrency(order.total);

  header.append(titleWrap, total);

  const itemList = document.createElement("div");
  itemList.className = "order-items";
  itemList.replaceChildren(...order.items.map(renderOrderItem));

  const paymentSummary = renderPaymentSummary(order);
  const checkoutLink = document.createElement("a");
  checkoutLink.className = "button primary";
  checkoutLink.href = `/checkout/?pedido=${encodeURIComponent(order.id)}`;
  checkoutLink.textContent = order.paymentStatus === "aprovado" ? "Ver checkout" : "Continuar pagamento";

  card.append(header, itemList, paymentSummary);
  const cancellationDetails = renderCancellationDetails(order);
  if (cancellationDetails) card.append(cancellationDetails);

  if (order.status !== "cancelado") {
    card.append(checkoutLink);
  }

  if (canCancelOrder(order)) {
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

function renderOrders(container, summary, orders, handlers) {
  const highlightedId = new URLSearchParams(window.location.search).get("pedido");
  const totalItems = orders.reduce((sum, order) => sum + order.items.length, 0);

  if (summary) {
    summary.textContent = `${orders.length} pedido${orders.length === 1 ? "" : "s"} encontrado${orders.length === 1 ? "" : "s"}.`;
  }

  if (!orders.length) {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.textContent = "Você ainda não finalizou nenhum pedido.";
    container.replaceChildren(empty);
    return;
  }

  container.replaceChildren(...orders.map((order) => renderOrderCard(order, highlightedId, handlers)));
  recordEvent("orders_view", { orders: orders.length, items: totalItems });
}

export async function initOrdersPage() {
  const container = document.querySelector("[data-orders-list]");
  const summary = document.querySelector("[data-orders-summary]");
  if (!container) return;
  let paymentEngine = null;
  let processingOrderId = "";

  async function refreshOrders() {
    try {
      const [orders, engine] = await Promise.all([
        loadOrders(),
        getPaymentEngineMetadata(),
      ]);
      paymentEngine = engine;
      renderOrders(container, summary, orders, {
        processingOrderId,
        onCancelOrder,
      });
    } catch (error) {
      container.replaceChildren();
      if (summary) summary.textContent = error.message;
    }
  }

  async function onCancelOrder(order, button) {
    processingOrderId = order.id;
    button.disabled = true;
    button.textContent = "Cancelando...";
    try {
      await cancelCustomerOrder(order, paymentEngine);
    } catch (error) {
      window.alert(error.message);
    } finally {
      processingOrderId = "";
      await refreshOrders();
    }
  }

  await refreshOrders();
}
