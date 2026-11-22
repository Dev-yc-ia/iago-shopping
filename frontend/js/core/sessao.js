import { BASE } from "../config/ranking.js";
import { consultar, definirCsrf, enviarAcao } from "./api.js";
import { elemento } from "./dom.js";
let emVoo = null;
let assinatura = null;
let conta = { autenticado: false };
export const sessaoAtual = () => conta;

function link(rotulo, destino) {
  const node = elemento("a", rotulo, "botao-entrar");
  node.href = new URL(destino, BASE);
  return node;
}

export function renderizarSessao(nova) {
  conta = nova;
  definirCsrf(nova.csrf_token);
  document.body.dataset.visao =
    nova.autenticado && !nova.trocar_senha ? nova.perfil : "publico";
  const chave = `${nova.id}:${nova.perfil}:${nova.trocar_senha}`;
  const topo = document.getElementById("conta");
  if (!topo || chave === assinatura) return;
  assinatura = chave;
  if (!nova.autenticado) {
    topo.replaceChildren(link("Entrar", "login/"));
    return;
  }
  const sair = elemento("button", "Sair");
  sair.type = "button";
  sair.addEventListener("click", async () => {
    sair.disabled = true;
    try {
      await enviarAcao("api/auth/logout");
      location.assign(BASE);
    } catch (erro) {
      sair.disabled = false;
      alert(erro.message);
    }
  });
  topo.replaceChildren(
    elemento(
      "span",
      `${nova.nome} · ${nova.perfil === "master" ? "Master" : "Juiz"}`,
    ),
    link("Alterar senha", "alterar-senha/"),
    sair,
  );
}

/** Compartilha a consulta em voo entre a página e o cabeçalho. */
export function carregarSessao() {
  if (emVoo) return emVoo;
  emVoo = consultar("api/sessao")
    .then((dados) => {
      renderizarSessao(dados);
      return dados;
    })
    .finally(() => {
      emVoo = null;
    });
  return emVoo;
}
carregarSessao().catch(() => {});
