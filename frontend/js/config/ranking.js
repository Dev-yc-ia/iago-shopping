/** URLs relativas à aplicação; nenhum segredo ou cadastro mora na configuração pública. */
export const BASE = new URL("../../", import.meta.url);
export const ENDPOINTS = Object.freeze({
  ranking: new URL("api/ranking", BASE),
  skatistas: new URL("api/skatistas", BASE),
});
export const HTTP_TIMEOUT_MS = 8000;
export const ATUALIZACAO_MS = 2000;
