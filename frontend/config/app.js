function normalizeApiBaseUrl(value) {
  return String(value || "").trim().replace(/\/+$/, "");
}

function resolveApiBaseUrl() {
  return "";
}

const API_BASE_URL = normalizeApiBaseUrl(resolveApiBaseUrl());
const apiEndpoint = (path) => `${API_BASE_URL}${path}`;

export const APP_CONFIG = {
  name: "IAGO Shopping",
  phase: "2",
  apiBaseUrl: API_BASE_URL,
  analyticsStorageKey: "iago-shopping-anonymous-events",
  anonymousSessionKey: "iago-shopping-anonymous-session",
  heroImagePath: "/assets/images/hero/tela_login.png",
  publicConfigEndpoint: apiEndpoint("/api/config/public"),
  publicConfigStaticPath: new URL("./public.json", import.meta.url).href,
  paymentEngineEndpoint: "payment-engine",
  paymentCreateEndpoint: "payment-create",
  paymentSyncEndpoint: "payment-sync",
  paymentCancelEndpoint: "payment-cancel",
  paymentProvider: "mock",
};
