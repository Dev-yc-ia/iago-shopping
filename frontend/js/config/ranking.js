/** URLs relativas ao frontend e endereço público da Edge Function. */
export const BASE = new URL("../../", import.meta.url);
const loopback = ["localhost", "127.0.0.1", "[::1]"].includes(BASE.hostname);
export const API_EDGE = loopback
  ? null
  : new URL("https://yoewqaatkoltozppohxu.supabase.co/functions/v1/iago-api/");
export const ENDPOINTS = Object.freeze({
  ranking: new URL("api/ranking", BASE),
  skatistas: new URL("api/skatistas", BASE),
});
export const HTTP_TIMEOUT_MS = 8000;
export const ATUALIZACAO_MS = 2000;
