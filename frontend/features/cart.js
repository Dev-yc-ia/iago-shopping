import { getSupabaseClient } from "./auth.js";
import { createProductImage } from "../ui/productImage.js";
import { recordEvent } from "../utils/analytics.js";
import { formatCurrency } from "../utils/format.js";

function currentRelativeUrl() {
  const page = window.location.pathname.split("/").pop() || "index.html";
  return `./${page}${window.location.search}`;
}

function redirectToCartLogin() {
  recordEvent("cart_login_required", { source: document.body.dataset.page || "unknown" });
  const redirect = encodeURIComponent(currentRelativeUrl());
  window.location.href = `./login.html?aviso=carrinho&redirect=${redirect}`;
}

async function getAuthenticatedCartClient() {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.auth.getSession();
  if (error) throw error;

  if (!data.session?.user) {
    redirectToCartLogin();
    return null;
  }

  return supabase;
}

function firstImageUrl(images = []) {
  const primary = images.find((image) => image.principal);
  return primary?.url || images[0]?.url || "";
}

function normalizeCartItem(item) {
  const images = Array.isArray(item.imagens) ? item.imagens : [];
  const quantity = Number(item.quantidade || 0);
  const unitPrice = Number(item.preco_unitario || 0);
  return {
    id: item.item_id,
    cartId: item.carrinho_id,
    productId: item.produto_id,
    sku: item.sku,
    name: item.nome,
    brand: item.marca,
    category: item.categoria,
    unitPrice,
    quantity,
    subtotal: Number(item.subtotal || unitPrice * quantity),
    availableStock: Number(item.estoque_disponivel || 0),
    imageUrl: firstImageUrl(images),
  };
}

async function loadCartItems() {
  const supabase = await getAuthenticatedCartClient();
  if (!supabase) return [];

  const { data, error } = await supabase.rpc("shopping_carrinho_atual");
  if (error) throw error;
  return (data || []).map(normalizeCartItem);
}

export async function addProductToCart(productId, quantity = 1) {
  const supabase = await getAuthenticatedCartClient();
  if (!supabase) return false;

  const { error } = await supabase.rpc("shopping_carrinho_adicionar_produto", {
    p_produto_id: productId,
    p_quantidade: quantity,
  });
  if (error) throw error;

  recordEvent("cart_add", { productId, quantity });
  return true;
}

async function updateCartItemQuantity(itemId, quantity) {
  const supabase = await getAuthenticatedCartClient();
  if (!supabase) return;

  if (quantity <= 0) {
    await removeCartItem(itemId);
    return;
  }

  const { error } = await supabase.rpc("shopping_carrinho_definir_quantidade", {
    p_item_id: itemId,
    p_quantidade: quantity,
  });
  if (error) throw error;
}

async function removeCartItem(itemId) {
  const supabase = await getAuthenticatedCartClient();
  if (!supabase) return;

  const { error } = await supabase.rpc("shopping_carrinho_remover_item", {
    p_item_id: itemId,
  });
  if (error) throw error;
}

async function finalizeCartOrder() {
  const supabase = await getAuthenticatedCartClient();
  if (!supabase) return null;

  const { data, error } = await supabase.rpc("shopping_pedido_finalizar_carrinho");
  if (error) throw error;

  const order = Array.isArray(data) ? data[0] : data;
  recordEvent("order_create", { orderId: order?.id });
  return order;
}

function renderCartItem(item, onChange) {
  const article = document.createElement("article");
  article.className = "cart-item";

  const image = createProductImage({
    src: item.imageUrl,
    alt: item.name,
    fallbackText: item.category,
    variant: "cart-thumb",
  });

  const content = document.createElement("div");
  content.className = "cart-item-content";

  const brand = document.createElement("span");
  brand.className = "card-kicker";
  brand.textContent = item.brand;

  const title = document.createElement("h2");
  title.textContent = item.name;

  const meta = document.createElement("p");
  meta.textContent = `${item.sku} | Estoque disponível: ${item.availableStock} un.`;

  const price = document.createElement("strong");
  price.textContent = formatCurrency(item.unitPrice);

  content.append(brand, title, meta, price);

  const controls = document.createElement("div");
  controls.className = "cart-item-controls";

  const decreaseButton = document.createElement("button");
  decreaseButton.className = "button ghost";
  decreaseButton.type = "button";
  decreaseButton.textContent = "-";
  decreaseButton.addEventListener("click", () => onChange(item.id, item.quantity - 1));

  const quantity = document.createElement("span");
  quantity.textContent = `${item.quantity}`;

  const increaseButton = document.createElement("button");
  increaseButton.className = "button ghost";
  increaseButton.type = "button";
  increaseButton.textContent = "+";
  increaseButton.disabled = item.quantity >= item.availableStock;
  increaseButton.addEventListener("click", () => onChange(item.id, item.quantity + 1));

  const subtotal = document.createElement("strong");
  subtotal.textContent = formatCurrency(item.subtotal);

  const removeButton = document.createElement("button");
  removeButton.className = "button secondary";
  removeButton.type = "button";
  removeButton.textContent = "Remover";
  removeButton.addEventListener("click", () => onChange(item.id, 0));

  controls.append(decreaseButton, quantity, increaseButton, subtotal, removeButton);
  article.append(image, content, controls);
  return article;
}

function renderCart(list, summary, total, count, checkoutButton, checkoutNote, items, onChange) {
  const totalQuantity = items.reduce((sum, item) => sum + item.quantity, 0);
  const totalValue = items.reduce((sum, item) => sum + item.subtotal, 0);

  if (!items.length) {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.textContent = "Seu carrinho está vazio. Escolha um produto publicado para começar.";
    list.replaceChildren(empty);
  } else {
    list.replaceChildren(...items.map((item) => renderCartItem(item, onChange)));
  }

  if (summary) {
    summary.textContent = `${totalQuantity} item${totalQuantity === 1 ? "" : "s"} no carrinho ativo.`;
  }
  if (total) total.textContent = formatCurrency(totalValue);
  if (count) count.textContent = `${items.length} produto${items.length === 1 ? "" : "s"} selecionado${items.length === 1 ? "" : "s"}.`;
  if (checkoutButton) checkoutButton.disabled = !items.length;
  if (checkoutNote) {
    checkoutNote.textContent = items.length
      ? "Ao finalizar, você segue para o checkout do pedido."
      : "Escolha produtos no catálogo para montar seu pedido.";
  }
}

export async function initCartPage() {
  const list = document.querySelector("[data-cart-list]");
  const summary = document.querySelector("[data-cart-summary]");
  const total = document.querySelector("[data-cart-total]");
  const count = document.querySelector("[data-cart-count]");
  const checkoutButton = document.querySelector("[data-cart-checkout]");
  const checkoutNote = document.querySelector("[data-cart-checkout-note]");
  if (!list) return;

  async function refreshCart() {
    try {
      const items = await loadCartItems();
      recordEvent("cart_view", { items: items.length });
      renderCart(list, summary, total, count, checkoutButton, checkoutNote, items, async (itemId, quantity) => {
        try {
          await updateCartItemQuantity(itemId, quantity);
          await refreshCart();
        } catch (error) {
          window.alert(error.message);
        }
      });
    } catch (error) {
      list.replaceChildren();
      if (summary) summary.textContent = error.message;
    }
  }

  checkoutButton?.addEventListener("click", async () => {
    checkoutButton.disabled = true;
    try {
      const order = await finalizeCartOrder();
      if (order?.id) {
        window.location.href = `./checkout.html?pedido=${encodeURIComponent(order.id)}`;
        return;
      }
      await refreshCart();
    } catch (error) {
      window.alert(error.message);
      await refreshCart();
    }
  });

  await refreshCart();
}
