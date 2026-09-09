import { getSupabaseClient } from "./auth.js";
import { createProductImage } from "../ui/productImage.js";
import { recordEvent } from "../utils/analytics.js";
import { formatCurrency } from "../utils/format.js";
import { PAYMENT_STATUS_LABELS } from "./payments.js";

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
  return {
    id: order.id,
    number: order.numero,
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
  if (order.paymentErrorCode === "mock_timeout") return "Tempo esgotado no processamento";
  if (order.paymentStatus === "expirado" && order.paymentMethod === "pix") return "PIX expirado";
  return PAYMENT_STATUS_LABELS[order.paymentStatus] || order.paymentStatus;
}

function paymentMessageText(order, isProcessing = false) {
  if (isProcessing) {
    return "Payment Engine processando a tentativa. O pedido será atualizado automaticamente.";
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

function renderOrderCard(order, highlightedId) {
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

  card.append(header, itemList, paymentSummary, checkoutLink);
  return card;
}

function renderOrders(container, summary, orders) {
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

  container.replaceChildren(...orders.map((order) => renderOrderCard(order, highlightedId)));
  recordEvent("orders_view", { orders: orders.length, items: totalItems });
}

export async function initOrdersPage() {
  const container = document.querySelector("[data-orders-list]");
  const summary = document.querySelector("[data-orders-summary]");
  if (!container) return;

  async function refreshOrders() {
    try {
      const orders = await loadOrders();
      renderOrders(container, summary, orders);
    } catch (error) {
      container.replaceChildren();
      if (summary) summary.textContent = error.message;
    }
  }

  await refreshOrders();
}
