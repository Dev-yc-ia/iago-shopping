const PRODUCTION_API_BASE_URL = "https://api.ia-go.api.br";
const PRODUCTION_FRONTEND_HOSTS = new Set(["ia-go.api.br", "www.ia-go.api.br"]);

function normalizeApiBaseUrl(value) {
  return String(value || "").trim().replace(/\/+$/, "");
}

function resolveApiBaseUrl() {
  if (typeof window === "undefined") return "";
  return PRODUCTION_FRONTEND_HOSTS.has(window.location.hostname)
    ? PRODUCTION_API_BASE_URL
    : "";
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
  paymentEngineEndpoint: apiEndpoint("/api/payments/engine"),
  paymentCreateEndpoint: apiEndpoint("/api/payments/create"),
  paymentSyncEndpoint: apiEndpoint("/api/payments/sync"),
  paymentCancelEndpoint: apiEndpoint("/api/payments/cancel"),
  paymentProvider: "mock",
};
