import { APP_CONFIG } from "../config/app.js";

function getSessionId() {
  const existing = window.localStorage.getItem(APP_CONFIG.anonymousSessionKey);
  if (existing) {
    return existing;
  }

  const sessionId = `anon-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  window.localStorage.setItem(APP_CONFIG.anonymousSessionKey, sessionId);
  return sessionId;
}

export function recordEvent(type, detail = {}) {
  const allowedTypes = new Set([
    "entry",
    "continue_without_login",
    "login_start",
    "product_view",
    "cart_login_required",
    "cart_add",
    "cart_view",
    "order_create",
    "orders_view",
    "checkout_view",
    "payment_attempt_create",
    "payment_attempt_cancel",
    "payment_brick_ready",
    "payment_provider_result",
  ]);
  if (!allowedTypes.has(type)) {
    return;
  }

  const previous = JSON.parse(window.localStorage.getItem(APP_CONFIG.analyticsStorageKey) || "[]");
  const event = {
    type,
    detail,
    sessionId: getSessionId(),
    createdAt: new Date().toISOString(),
  };

  previous.push(event);
  window.localStorage.setItem(APP_CONFIG.analyticsStorageKey, JSON.stringify(previous.slice(-100)));
}
