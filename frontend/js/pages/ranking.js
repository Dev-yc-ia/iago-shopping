import { ATUALIZACAO_MS } from "../config/ranking.js";
import { obterRanking, consultar, enviarAcao } from "../core/api.js";
import { carregarSessao, sessaoAtual } from "../core/sessao.js";
import { criarVisualizacao, formatarNota } from "../features/ranking-render.js";
const $ = (id) => document.getElementById(id);
const visualizacao = criarVisualizacao();
let dados = { categorias: [], inscricoes: [], pista: null };
let grupoSelecionado = null;
let revisaoFiltro = -1n;
function aplicarFiltro(filtro, grupos = dados.grupos ?? []) {
  const revisao = BigInt(filtro?.revisao ?? 0);
  if (revisao > revisaoFiltro) {
    revisaoFiltro = revisao;
    grupoSelecionado = grupos.some(g => g.chave === filtro?.grupo) ? filtro.grupo : grupos[0]?.chave ?? null;
  }
  if (!grupos.some(g => g.chave === grupoSelecionado)) grupoSelecionado = grupos[0]?.chave ?? null;
}
let privado = null;
let tentativaAtual = null;
let emVoo = false;
let pendente = false;
let timer;
let acaoEmVoo = false;

/** Uma consulta por ciclo; ações e retorno à aba solicitam atualização imediata sem sobreposição. */
async function atualizar() {
  if (emVoo) {
    pendente = true;
    return;
  }
  clearTimeout(timer);
  emVoo = true;
  try {
    const [ranking, sessao] = await Promise.all([
      obterRanking(),
      carregarSessao(),
    ]);
    const estado =
      sessao.autenticado && !sessao.trocar_senha
        ? await consultar("api/competicao/estado")
        : null;
    aplicarFiltro(ranking.filtro, ranking.grupos ?? []);
    dados = ranking;
    privado = estado;
    if (tentativaAtual !== dados.pista?.id) {
      tentativaAtual = dados.pista?.id ?? null;
      if (tentativaAtual) $("feedback").textContent = "";
      $("nota").value = "";
      $("recibo").textContent = "";
    }
    visualizacao.renderizar(dados, sessao, privado, acaoEmVoo, grupoSelecionado);
    visualizacao.mostrarCarga(
      "pronto",
      dados.inscricoes.length ? "" : "Cadastro vazio. Execute a importação local.",
    );
    } catch (erro) {
    visualizacao.mostrarCarga("erro", erro.message);
  } finally {
    emVoo = false;
    if (pendente) {
      pendente = false;
      atualizar();
    } else timer = setTimeout(atualizar, ATUALIZACAO_MS);
  }
}
async function executar(rota, corpo, alvo = null) {
  if (acaoEmVoo) return;
  acaoEmVoo = true;
  visualizacao.renderizar(dados, sessaoAtual(), privado, true, grupoSelecionado);
  try {
    const resposta = await enviarAcao(rota, corpo);
    if (resposta.filtro) aplicarFiltro(resposta.filtro);
    // Uma resposta da tentativa anterior nunca limpa ou confirma a nota de uma nova tentativa.
    if (!alvo || tentativaAtual === alvo) {
      $("feedback").textContent = resposta.recibo
        ? `Nota ${formatarNota(resposta.recibo.nota)} recebida. Recibo ${resposta.recibo.id}`
        : (resposta.mensagem ?? "Pista atualizada.");
      if (resposta.recibo) $("nota").value = "";
    }
  } catch (erro) {
    if (!alvo || tentativaAtual === alvo)
      $("feedback").textContent = erro.message;
  } finally {
    acaoEmVoo = false;
    await atualizar();
  }
}
const selecao = () => ({
  inscricao_id: $("atleta").value,
  volta: Number($("volta").value),
});
$("chamada").addEventListener("submit", (e) => {
  e.preventDefault();
  executar("api/competicao/abrir", selecao());
});
$("chamar").addEventListener("click", () =>
  executar("api/competicao/chamar", selecao()),
);
$("cancelamento").addEventListener("submit", (e) => {
  e.preventDefault();
  const id = tentativaAtual;
  if (
    id &&
    confirm(
      "Cancelar esta tentativa? Os votos serão preservados internamente e não contarão no ranking.",
    )
  )
    executar(
      `api/competicao/${id}/cancelar`,
      { motivo: $("motivo").value },
      id,
    );
});
$("votacao").addEventListener("submit", (e) => {
  e.preventDefault();
  const id = tentativaAtual;
  const nota = $("nota").value.trim();
  if (
    !/^\d{1,3}([.,]\d{1,2})?$/.test(nota) ||
    Number(nota.replace(",", ".")) > 100
  ) {
    $("feedback").textContent =
      "Informe nota de 0 a 100 com até duas casas decimais.";
    return;
  }
  const pista = dados.pista;
  if (
    id &&
    confirm(
      `Confirmar nota ${nota} para #${pista.numero_provisorio} · ${pista.nome}, V${pista.volta}? A nota não poderá ser alterada.`,
    )
  )
    executar(`api/competicao/${id}/votos`, { nota }, id);
});
for (const id of ["atleta", "volta"])
  $(id).addEventListener("change", () =>
    visualizacao.renderizar(dados, sessaoAtual(), privado, acaoEmVoo, grupoSelecionado),
  );
$("filtros-ranking").addEventListener("click", (e) => {
  const botao = e.target.closest("button[data-grupo]");
  if (!botao || acaoEmVoo) return;
  const sessao = sessaoAtual();
  if (sessao.perfil === "master" && !sessao.trocar_senha) {
    executar("api/competicao/filtro", { grupo: botao.dataset.grupo });
  } else {
    grupoSelecionado = botao.dataset.grupo;
    visualizacao.renderizar(dados, sessao, privado, acaoEmVoo, grupoSelecionado);
  }
});
$("tentar").addEventListener("click", atualizar);
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) atualizar();
});
window.addEventListener("online", atualizar);
atualizar();
