import { BASE, ENDPOINTS, HTTP_TIMEOUT_MS } from "../config/ranking.js";
let csrf = "";
export function definirCsrf(valor) {
  csrf = valor || "";
}

/** Cookies ficam HttpOnly; mutações usam também origem e token CSRF da sessão. */
export async function consultar(caminho, { method = "GET", dados, arquivo } = {}) {
  let resposta;
  try {
    resposta = await fetch(new URL(caminho, BASE), {
      method,
      credentials: "same-origin",
      cache: "no-store",
      signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
      headers: {
        Accept: "application/json",
        ...(dados ? { "Content-Type": "application/json" } : {}),
        ...(method !== "GET" ? { "X-CSRF-Token": csrf } : {}),
      },
      ...(arquivo ? { body: arquivo } : dados ? { body: JSON.stringify(dados) } : {}),
    });
  } catch {
    throw new Error(
      "Conexão interrompida. Tentando reconectar ao servidor local…",
    );
  }
  const corpo = await resposta.json().catch(() => ({}));
  if (!resposta.ok) {
    const erro = new Error(
      typeof corpo.detail === "string"
        ? corpo.detail
        : "Não foi possível concluir. Tente novamente.",
    );
    erro.status = resposta.status;
    throw erro;
  }
  return corpo;
}
export const obterRanking = () => consultar(ENDPOINTS.ranking);
export const importarSkatistas = (arquivo) =>
  consultar("api/skatistas/importar?nome=" + encodeURIComponent(arquivo.name), {
    method: "POST", arquivo,
  });
export const obterSkatistas = () => consultar(ENDPOINTS.skatistas);
export const enviarAcao = (rota, dados, method = "POST") =>
  consultar(rota, { method, dados });
