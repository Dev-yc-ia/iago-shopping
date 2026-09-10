import { getSupabaseClient } from "./auth.js";
import { createProductImage } from "../ui/productImage.js";
import { recordEvent } from "../utils/analytics.js";
import { formatCurrency } from "../utils/format.js";
import {
  PAYMENT_METHOD_LABELS,
  PAYMENT_STATUS_LABELS,
  cancelPaymentAttempt,
  getPaymentEngineMetadata,
  isMercadoPagoEngine,
  mountMercadoPagoPaymentBrick,
  startPayment,
  syncMercadoPagoPayment,
} from "./payments.js";

const VALID_PAYMENT_METHODS = new Set(Object.keys(PAYMENT_METHOD_LABELS));

function currentRelativeUrl() {
  return `/checkout/${window.location.search}`;
}

function redirectToCheckoutLogin() {
  const redirect = encodeURIComponent(currentRelativeUrl());
  window.location.href = `/login/?aviso=pedidos&redirect=${redirect}`;
}

async function getAuthenticatedCheckoutClient() {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.auth.getSession();
  if (error) throw error;

  if (!data.session?.user) {
    redirectToCheckoutLogin();
    return null;
  }

  return supabase;
}

async function loadPreferredPaymentMethod() {
  try {
    const supabase = await getSupabaseClient();
    const { data: sessionData, error: sessionError } = await supabase.auth.getSession();
    if (sessionError) throw sessionError;
    if (!sessionData.session?.user) return "pix";

    const { data, error } = await supabase.rpc("shopping_perfil_atual");
    if (error) throw error;

    const preferredMethod = data?.[0]?.pagamento_preferido;
    return VALID_PAYMENT_METHODS.has(preferredMethod) ? preferredMethod : "pix";
  } catch (error) {
    console.warn(`Não foi possível carregar a preferência de pagamento: ${error.message}`);
    return "pix";
  }
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
    paymentProviderPaymentId: order.pagamento_provider_payment_id || "",
    paymentQrCodeBase64: order.pagamento_qr_code_base64 || "",
    paymentQrCodeUrl: order.pagamento_qr_code_url || "",
    paymentCopyPaste: order.pagamento_copia_cola || "",
    paymentUrl: order.pagamento_payment_url || "",
    paymentExpirationDate: order.pagamento_expiration_date || "",
    paymentProviderStatus: order.pagamento_provider_status || "",
    total: Number(order.total || 0),
    currency: order.moeda || "BRL",
    createdAt: order.criado_em,
    items: items.map((item) => ({
      id: item.item_id,
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

async function loadCheckoutOrder() {
  const supabase = await getAuthenticatedCheckoutClient();
  if (!supabase) return null;

  const orderId = new URLSearchParams(window.location.search).get("pedido");
  const { data, error } = await supabase.rpc("shopping_pedidos_cliente_listar");
  if (error) throw error;

  const orders = (data || []).map(normalizeOrder);
  return orderId ? orders.find((order) => order.id === orderId) || null : orders[0] || null;
}

function paymentStatusText(order, processing = false) {
  if (processing) return "Processando pagamento";
  if (order.status === "cancelado") return "Pedido cancelado";
  if (order.paymentErrorCode === "mock_timeout") return "Tempo esgotado";
  if (order.paymentStatus === "expirado" && order.paymentMethod === "pix") return "PIX expirado";
  return PAYMENT_STATUS_LABELS[order.paymentStatus] || order.paymentStatus;
}

function paymentMessage(order, processing = false, method = order.paymentMethod) {
  if (processing && (method === "cartao_debito" || method === "cartao_credito")) {
    return "Tokenizando cartão, enviando ao Mercado Pago e aguardando confirmação automática.";
  }
  if (processing) return "Gerando pagamento Pix e aguardando confirmação automática do provider.";
  if (order.status === "cancelado") return "Pedido cancelado. O histórico permanece em Meus pedidos.";
  if (order.paymentStatus === "aprovado") {
    return "Pagamento confirmado. Seu pedido foi encaminhado ao parceiro responsável. Acompanhe a entrega em Meus Pedidos.";
  }
  if (order.paymentErrorMessage) return order.paymentErrorMessage;
  if (order.paymentStatus === "recusado") return "Pagamento recusado. Você pode iniciar uma nova tentativa com outro método.";
  if (order.paymentStatus === "expirado") return "Pagamento expirado. Gere uma nova tentativa para continuar.";
  if (
    order.paymentMethod === "pix"
    && order.paymentId
    && !order.paymentQrCodeBase64
    && !order.paymentQrCodeUrl
    && !order.paymentCopyPaste
  ) {
    return "Mercado Pago ainda não retornou QR Code nem Pix Copia e Cola para esta tentativa.";
  }
  if (order.paymentId) return "Pagamento aguardando confirmação automática do provider.";
  return "Escolha a forma de pagamento para continuar.";
}

function isFinalPaymentStatus(status) {
  return ["aprovado", "recusado", "expirado", "cancelado"].includes(status);
}

function hasActivePaymentAttempt(order) {
  return Boolean(order?.paymentId) && !isFinalPaymentStatus(order.paymentStatus);
}

function canCancelPayment(order) {
  return hasActivePaymentAttempt(order) && order.paymentStatus !== "aprovado";
}

function secondsUntilExpiration(value) {
  if (!value) return null;
  const expiration = new Date(value).getTime();
  if (Number.isNaN(expiration)) return null;
  return Math.max(0, Math.floor((expiration - Date.now()) / 1000));
}

function formatCountdown(totalSeconds) {
  if (totalSeconds === null) return "--:--";
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
}

function startCountdown(element, expirationDate, onExpire) {
  let expired = false;
  const render = () => {
    const remaining = secondsUntilExpiration(expirationDate);
    if (remaining === 0) {
      element.textContent = "PIX expirado";
      element.classList.add("is-expired");
      if (!expired) {
        expired = true;
        window.clearInterval(timer);
        if (onExpire) onExpire();
      }
      return;
    }
    element.textContent = `Expira em ${formatCountdown(remaining)}`;
    element.classList.remove("is-expired");
  };
  const timer = window.setInterval(render, 1000);
  render();
}

function renderItem(item) {
  const row = document.createElement("div");
  row.className = "checkout-item";

  const image = createProductImage({
    src: item.imageUrl,
    alt: item.name,
    fallbackText: item.category,
    variant: "cart-thumb",
  });

  const content = document.createElement("div");
  content.className = "checkout-item-content";

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

function renderSteps(order) {
  const steps = document.createElement("div");
  steps.className = "checkout-steps";

  const hasPayment = Boolean(order.paymentId);
  const isApproved = order.paymentStatus === "aprovado";
  const stages = [
    ["Pedido criado", true],
    ["Pagamento gerado", hasPayment],
    ["Aguardando pagamento", hasPayment && !isFinalPaymentStatus(order.paymentStatus)],
    ["Pagamento confirmado", isApproved],
    ["Aguardando parceiro", isApproved],
    ["Recebimento confirmado", false],
  ];

  stages.forEach(([label, active]) => {
    const step = document.createElement("span");
    step.className = "checkout-step";
    step.classList.toggle("is-active", Boolean(active));
    step.textContent = label;
    steps.append(step);
  });

  return steps;
}

function renderPixBox(order, onRefresh, onExpire) {
  if (!order.paymentId) return null;

  const box = document.createElement("div");
  box.className = "checkout-pix-box";

  const qrCodeUrl = order.paymentQrCodeUrl || order.paymentUrl;

  if (order.paymentQrCodeBase64) {
    const qr = document.createElement("img");
    qr.className = "checkout-pix-qr";
    qr.src = `data:image/png;base64,${order.paymentQrCodeBase64}`;
    qr.alt = "QR Code Pix";
    box.append(qr);
  } else {
    const pendingQr = document.createElement("div");
    pendingQr.className = "checkout-pix-qr checkout-pix-qr-empty";
    pendingQr.textContent = qrCodeUrl ? "PIX disponível" : "PIX";
    box.append(pendingQr);
  }

  const content = document.createElement("div");
  content.className = "checkout-pix-content";

  const countdown = document.createElement("strong");
  countdown.className = "checkout-pix-countdown";
  startCountdown(countdown, order.paymentExpirationDate, onExpire);

  const code = document.createElement("textarea");
  code.readOnly = true;
  code.value = order.paymentCopyPaste
    || order.paymentErrorMessage
    || "Mercado Pago ainda não retornou Pix Copia e Cola.";
  code.setAttribute("aria-label", "Pix copia e cola");

  const actions = document.createElement("div");
  actions.className = "checkout-actions";

  const copy = document.createElement("button");
  copy.className = "button primary";
  copy.type = "button";
  copy.textContent = "Copiar código Pix";
  copy.disabled = !order.paymentCopyPaste;
  copy.addEventListener("click", async () => {
    await navigator.clipboard.writeText(order.paymentCopyPaste);
    copy.textContent = "Código copiado";
  });

  const refresh = document.createElement("button");
  refresh.className = "button";
  refresh.type = "button";
  refresh.textContent = "Atualizar status";
  refresh.addEventListener("click", onRefresh);

  actions.append(copy, refresh);
  if (qrCodeUrl) {
    const qrLink = document.createElement("a");
    qrLink.className = "button";
    qrLink.href = qrCodeUrl;
    qrLink.target = "_blank";
    qrLink.rel = "noopener noreferrer";
    qrLink.textContent = "Abrir Pix";
    actions.append(qrLink);
  }
  content.append(countdown, code, actions);
  box.append(content);
  return box;
}

function renderCancelPaymentButton(order, handlers) {
  if (!canCancelPayment(order)) return null;

  const button = document.createElement("button");
  button.className = "button secondary checkout-cancel-payment";
  button.type = "button";
  button.disabled = handlers.processing;
  button.textContent = order.paymentMethod === "pix" ? "Cancelar Pix" : "Cancelar pagamento";
  button.addEventListener("click", handlers.onCancelPayment);
  return button;
}

function renderMethodSelector(selectedMethod, onSelect) {
  const wrap = document.createElement("div");
  wrap.className = "checkout-methods";

  Object.entries(PAYMENT_METHOD_LABELS).forEach(([method, label]) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "checkout-method";
    button.classList.toggle("is-selected", method === selectedMethod);
    button.textContent = label;
    button.addEventListener("click", () => onSelect(method));
    wrap.append(button);
  });

  return wrap;
}

function renderCheckout(root, summary, order, paymentEngine, selectedMethod, handlers) {
  if (handlers.onBeforeRender) handlers.onBeforeRender();

  if (!order) {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.textContent = "Pedido não encontrado para checkout.";
    root.replaceChildren(empty);
    if (summary) summary.textContent = "Nenhum pedido disponível.";
    return;
  }

  if (summary) summary.textContent = `Pedido #${order.number} | ${formatCurrency(order.total)}`;

  const review = document.createElement("section");
  review.className = "checkout-review";
  review.append(renderSteps(order));

  const title = document.createElement("h2");
  title.textContent = `Pedido #${order.number}`;

  const items = document.createElement("div");
  items.className = "checkout-items";
  items.replaceChildren(...order.items.map(renderItem));

  review.append(title, items);

  const panel = document.createElement("aside");
  panel.className = "checkout-payment-panel";
  panel.dataset.status = order.paymentStatus;

  const status = document.createElement("span");
  status.className = "card-kicker";
  status.textContent = paymentStatusText(order, handlers.processing);

  const total = document.createElement("h2");
  total.textContent = formatCurrency(order.total);

  const message = document.createElement("p");
  message.className = "payment-status-message";
  message.textContent = paymentMessage(order, handlers.processing, selectedMethod);

  panel.append(status, total, message);

  if (order.status !== "cancelado" && order.paymentStatus !== "aprovado") {
    const activeAttempt = hasActivePaymentAttempt(order);
    panel.append(renderMethodSelector(selectedMethod, handlers.onMethodSelect));

    const isCardMethod = selectedMethod === "cartao_debito" || selectedMethod === "cartao_credito";
    const isMercadoPago = isMercadoPagoEngine(paymentEngine);

    if (selectedMethod === "pix" && order.paymentMethod === "pix" && order.paymentId) {
      const pixBox = renderPixBox(order, handlers.onSync, handlers.onPixExpire);
      if (pixBox) panel.append(pixBox);
    }

    const cancelButton = renderCancelPaymentButton(order, handlers);
    if (cancelButton) panel.append(cancelButton);

    if (isMercadoPago && isCardMethod && !activeAttempt) {
      const brick = document.createElement("div");
      brick.className = "mercado-pago-brick checkout-brick";
      brick.id = `checkout-payment-brick-${order.id}`;
      panel.append(brick);

      if (!paymentEngine.public_key) {
        brick.textContent = "MERCADO_PAGO_PUBLIC_KEY precisa estar configurada para carregar o Brick.";
      } else {
        mountMercadoPagoPaymentBrick({
          container: brick,
          publicKey: paymentEngine.public_key,
          amount: order.total,
          method: selectedMethod,
          onSubmit: handlers.onCardSubmit,
          onError: handlers.onError,
        })
          .then((controller) => {
            if (handlers.onBrickMounted) handlers.onBrickMounted(controller);
          })
          .catch(handlers.onError);
      }
    } else if (!activeAttempt) {
      const button = document.createElement("button");
      button.className = "button primary checkout-pay-button";
      button.type = "button";
      button.disabled = handlers.processing;
      button.textContent = selectedMethod === "pix"
        ? (order.paymentId ? "Gerar novo Pix" : "Gerar Pix")
        : (order.paymentId ? "Tentar outro pagamento" : "Iniciar pagamento");
      button.addEventListener("click", handlers.onStartPayment);
      panel.append(button);
    }
  }

  const links = document.createElement("div");
  links.className = "checkout-actions";
  const ordersLink = document.createElement("a");
  ordersLink.className = "button";
  ordersLink.href = "/pedidos/";
  ordersLink.textContent = "Ver pedidos";
  const cartLink = document.createElement("a");
  cartLink.className = "button";
  cartLink.href = "/carrinho/";
  cartLink.textContent = "Voltar ao carrinho";
  links.append(ordersLink, cartLink);
  panel.append(links);

  root.replaceChildren(review, panel);
  recordEvent("checkout_view", {
    orderId: order.id,
    status: order.paymentStatus,
    provider: paymentEngine?.provider || "mock",
  });
}

export async function initCheckoutPage() {
  const root = document.querySelector("[data-checkout-root]");
  const summary = document.querySelector("[data-checkout-summary]");
  if (!root) return;

  let selectedMethod = await loadPreferredPaymentMethod();
  let paymentEngine = null;
  let currentOrder = null;
  let processing = false;
  let syncTimer = null;
  let paymentBrickController = null;

  async function syncCurrentPayment() {
    if (!currentOrder?.paymentId || !currentOrder.paymentProviderPaymentId) return;
    try {
      await syncMercadoPagoPayment({
        id: currentOrder.paymentId,
        provider_payment_id: currentOrder.paymentProviderPaymentId,
      });
      await refresh();
    } catch (error) {
      console.warn(error.message);
    }
  }

  function scheduleSync() {
    if (syncTimer) window.clearInterval(syncTimer);
    if (
      !isMercadoPagoEngine(paymentEngine) ||
      !currentOrder?.paymentProviderPaymentId ||
      isFinalPaymentStatus(currentOrder.paymentStatus)
    ) {
      return;
    }
    const interval = Math.max(1500, Number(paymentEngine.poll_interval_ms || 3000));
    syncTimer = window.setInterval(syncCurrentPayment, interval);
  }

  function unmountPaymentBrick() {
    if (!paymentBrickController) return;
    try {
      paymentBrickController.unmount();
    } catch (error) {
      console.warn(error.message);
    } finally {
      paymentBrickController = null;
    }
  }

  async function refresh() {
    try {
      [currentOrder, paymentEngine] = await Promise.all([
        loadCheckoutOrder(),
        getPaymentEngineMetadata(),
      ]);
      if (hasActivePaymentAttempt(currentOrder) || currentOrder?.paymentStatus === "aprovado") {
        selectedMethod = currentOrder.paymentMethod || selectedMethod;
      }
      renderCheckout(root, summary, currentOrder, paymentEngine, selectedMethod, {
        processing,
        onMethodSelect: selectPaymentMethod,
        onStartPayment: startCurrentPayment,
        onCardSubmit: submitCardPayment,
        onCancelPayment: cancelCurrentPayment,
        onSync: syncCurrentPayment,
        onPixExpire: syncCurrentPayment,
        onBeforeRender: unmountPaymentBrick,
        onBrickMounted: (controller) => {
          paymentBrickController = controller;
        },
        onError: showError,
      });
      scheduleSync();
    } catch (error) {
      root.replaceChildren();
      if (summary) summary.textContent = error.message;
    }
  }

  function handlers() {
    return {
      processing,
      onMethodSelect: selectPaymentMethod,
      onStartPayment: startCurrentPayment,
      onCardSubmit: submitCardPayment,
      onCancelPayment: cancelCurrentPayment,
      onSync: syncCurrentPayment,
      onPixExpire: syncCurrentPayment,
      onBeforeRender: unmountPaymentBrick,
      onBrickMounted: (controller) => {
        paymentBrickController = controller;
      },
      onError: showError,
    };
  }

  function showError(error) {
    window.alert(error.message || "Não foi possível processar o pagamento.");
  }

  function stopPolling() {
    if (syncTimer) {
      window.clearInterval(syncTimer);
      syncTimer = null;
    }
  }

  async function selectPaymentMethod(method) {
    if (!currentOrder || method === selectedMethod) return;
    const shouldCancelPix = (
      method !== "pix"
      && currentOrder.paymentMethod === "pix"
      && hasActivePaymentAttempt(currentOrder)
    );
    selectedMethod = method;

    if (!shouldCancelPix) {
      renderCheckout(root, summary, currentOrder, paymentEngine, selectedMethod, handlers());
      return;
    }

    processing = true;
    stopPolling();
    renderCheckout(root, summary, currentOrder, paymentEngine, selectedMethod, handlers());
    try {
      await cancelPaymentAttempt(currentOrder, paymentEngine);
    } catch (error) {
      selectedMethod = "pix";
      showError(error);
    } finally {
      processing = false;
      await refresh();
    }
  }

  async function cancelCurrentPayment() {
    if (!currentOrder?.paymentId) return;
    processing = true;
    stopPolling();
    renderCheckout(root, summary, currentOrder, paymentEngine, selectedMethod, handlers());
    try {
      await cancelPaymentAttempt(currentOrder, paymentEngine);
      await refresh();
    } catch (error) {
      showError(error);
    } finally {
      processing = false;
      await refresh();
    }
  }

  async function startCurrentPayment() {
    if (!currentOrder) return;
    processing = true;
    renderCheckout(root, summary, currentOrder, paymentEngine, selectedMethod, handlers());
    try {
      await startPayment(currentOrder.id, selectedMethod, paymentEngine);
      await refresh();
    } catch (error) {
      showError(error);
    } finally {
      processing = false;
      await refresh();
    }
  }

  async function submitCardPayment(formData) {
    if (!currentOrder) return;
    processing = true;
    renderCheckout(root, summary, currentOrder, paymentEngine, selectedMethod, handlers());
    try {
      await startPayment(currentOrder.id, selectedMethod, paymentEngine, formData);
      await refresh();
    } catch (error) {
      showError(error);
    } finally {
      processing = false;
      await refresh();
    }
  }

  await refresh();
}
