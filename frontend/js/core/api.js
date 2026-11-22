import { API_EDGE, BASE, ENDPOINTS, HTTP_TIMEOUT_MS } from "../config/ranking.js";

const sessionKey = "iago-session:" + BASE.pathname;
let csrf = "";
export function definirCsrf(valor) {
  csrf = valor || "";
}

export async function consultar(caminho, { method = "GET", dados, arquivo } = {}) {
  const local = new URL(caminho, BASE);
  const relative = local.pathname.slice(BASE.pathname.length);
  const destino = API_EDGE ? new URL(relative.replace(/^api\//, "") + local.search, API_EDGE) : local;
  const rota = relative.split("?")[0];
  const token = API_EDGE ? sessionStorage.getItem(sessionKey) : null;
  let resposta;
  try {
    resposta = await fetch(destino, {
      method,
      credentials: API_EDGE ? "omit" : "same-origin",
      cache: "no-store",
      signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
      headers: {
        Accept: "application/json",
        ...(dados ? { "Content-Type": "application/json" } : {}),
        ...(token && rota !== "api/ranking" && rota !== "api/auth/login" ? { Authorization: "Bearer " + token } : {}),
        ...(method !== "GET" && rota !== "api/auth/login" ? { "X-CSRF-Token": csrf } : {}),
      },
      ...(arquivo ? { body: arquivo } : dados ? { body: JSON.stringify(dados) } : {}),
    });
  } catch {
    throw new Error("Conexão interrompida. Tente novamente.");
  }
  const corpo = await resposta.json().catch(() => ({}));
  if (API_EDGE) {
    if (resposta.ok && typeof corpo.token === "string" &&
        (rota === "api/auth/login" || rota === "api/auth/senha")) {
      sessionStorage.setItem(sessionKey, corpo.token);
      delete corpo.token;
    } else if (token && token === sessionStorage.getItem(sessionKey) &&
        (resposta.status === 401 || (resposta.ok &&
          (rota === "api/auth/logout" || (rota === "api/sessao" && corpo.autenticado === false))))) {
      sessionStorage.removeItem(sessionKey);
    }
  }
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
