import { elemento, opcoes } from "../core/dom.js";
const IDS = [
  "filtros-ranking",
  "ranking",
  "titulo-categoria",
  "status",
  "pista",
  "atleta",
  "volta",
  "chamar",
  "liberar",
  "enviar",
  "contador",
  "pendentes",
  "orientacao",
  "master",
  "juiz",
  "carga",
  "tentar",
  "cancelamento",
  "recibo",
];
export const formatarNota = (nota) =>
  nota === null || nota === undefined
    ? "—"
    : Number(nota).toLocaleString("pt-BR", {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
      });

/** Dados públicos contêm só médias fechadas. Este módulo não calcula nem recebe votos alheios. */
export function criarVisualizacao() {
  const dom = Object.fromEntries(
    IDS.map((id) => [id, document.getElementById(id)]),
  );
  function mostrarCarga(situacao, mensagem) {
    dom.carga.textContent = mensagem;
    dom.tentar.hidden = situacao !== "erro";
  }
  function renderizarTabela(dados, grupoSelecionado) {
    const pista = dados.pista;
    const linhas = dados.inscricoes
      .filter((atleta) => atleta.grupo === grupoSelecionado)
      .map((atleta) => {
        const linha = elemento("tr");
        const ativo = pista?.inscricao_id === atleta.id;
        if (ativo) linha.className = "ativo";
        const nome = elemento("td", "", "nome");
        nome.append(
          elemento("span", `#${atleta.numero_provisorio}`, "numero texto-ranking"),
          elemento("span", atleta.nome, "texto-ranking"),
        );
        const celulas = [1, 2].map((volta) => {
          const td = elemento("td");
          td.append(elemento("span", formatarNota(atleta[`v${volta}`]), "texto-ranking"));
          if (ativo && pista.volta === volta) {
            td.className = "volta-ativa";
            td.append(
              elemento(
                "span",
                pista.estado === "aberta" ? "Recebendo notas" : "Na pista",
                "selo-pista texto-ranking",
              ),
            );
          }
          return td;
        });
        const nf = elemento("td");
        const circulo = elemento("span", "", "nf");
        circulo.append(elemento("span", formatarNota(atleta.nf), "texto-ranking"));
        nf.append(circulo);
        linha.append(
          celulaTexto(atleta.posicao ?? "—"),
          nome,
          ...celulas,
          nf,
        );
        return linha;
      });
    if (!linhas.length) {
      const tr = elemento("tr");
      const td = celulaTexto("Nenhum competidor neste grupo.");
      td.colSpan = 5;
      tr.append(td);
      linhas.push(tr);
    }
    dom.ranking.replaceChildren(...linhas);
  }
  function celulaTexto(texto) {
    const td = elemento("td");
    td.append(elemento("span", texto, "texto-ranking"));
    return td;
  }
  let assinatura = "";
  function renderizar(dados, sessao, privado, ocupada = false, grupoSelecionado = null) {
    const grupos = dados.grupos ?? [];
    const nova = JSON.stringify(grupos.map(g => [g.chave, g.rotulo]));
    if (nova !== assinatura) {
      dom["filtros-ranking"].replaceChildren(...grupos.map(g => {
        const botao = elemento("button", g.rotulo);
        botao.type = "button";
        botao.dataset.grupo = g.chave;
        return botao;
      }));
      assinatura = nova;
    }
    for (const botao of dom["filtros-ranking"].children) {
      botao.setAttribute("aria-pressed", String(botao.dataset.grupo === grupoSelecionado));
      botao.disabled = ocupada;
    }
    dom["titulo-categoria"].textContent = grupos.find(g => g.chave === grupoSelecionado)?.rotulo ?? "Classificação local";
    renderizarTabela(dados, grupoSelecionado);
    const pista = dados.pista;
    if (privado?.tentativa?.id !== pista?.id) privado = null;
    dom.status.textContent = pista
      ? pista.estado === "aberta"
        ? "Recebendo notas"
        : "Na pista"
      : "Aguardando chamada";
    dom.pista.textContent = pista
      ? `Na pista: #${pista.numero_provisorio} · ${pista.nome} · Categoria ${pista.categoria} · V${pista.volta} · ${pista.estado === "aberta" ? "Recebendo notas" : "Aguardando liberação"}`
      : "Pista livre · aguardando o próximo competidor";
    dom.master.hidden =
      !sessao.autenticado || sessao.perfil !== "master" || sessao.trocar_senha;
    dom.juiz.hidden =
      !sessao.autenticado || sessao.perfil !== "juiz" || sessao.trocar_senha;
    opcoes(
      dom.atleta,
      dados.inscricoes
        .map((a) => ({
          valor: a.id,
          rotulo: `#${a.numero_provisorio} · ${a.nome}`,
        })),
    );
    const selecionado = dados.inscricoes.find((a) => a.id === dom.atleta.value);
    const pronta = dados.voltas_concluidas_hoje?.some(
      ({ inscricao_id, volta }) => inscricao_id === selecionado?.id && volta === Number(dom.volta.value),
    );
    dom.chamar.disabled = ocupada || !!pista || !selecionado || pronta;
    const mesmaChamada =
      pista?.estado === "chamada" &&
      pista.inscricao_id === selecionado?.id &&
      pista.volta === Number(dom.volta.value);
    dom.liberar.disabled =
      ocupada || (!!pista && !mesmaChamada) || !selecionado || pronta;
    dom.cancelamento.hidden = !pista;
    dom.contador.textContent =
      privado?.total !== undefined
        ? `${privado.recebidos} de ${privado.total} notas recebidas`
        : "";
    dom.pendentes.textContent = privado?.pendentes?.length
      ? `Aguardando: ${privado.pendentes.map((j) => j.nome).join(", ")}`
      : "";
    const podeVotar =
      privado?.tentativa?.id === pista?.id &&
      privado?.elegivel &&
      !privado?.enviado &&
      pista?.estado === "aberta";
    dom.enviar.disabled = ocupada || !podeVotar;
    dom.orientacao.textContent = !pista
      ? "Aguarde a liberação do master."
      : privado?.enviado
        ? "Sua nota foi recebida. Aguarde o fechamento da volta."
        : !privado?.elegivel && pista.estado === "aberta"
          ? "Sua conta não integra a banca desta tentativa."
          : `#${pista.numero_provisorio} · ${pista.nome} · V${pista.volta}${pista.estado === "chamada" ? " · Aguarde a liberação." : ""}`;
    dom.recibo.textContent = privado?.recibo
      ? `Nota enviada: ${formatarNota(privado.recibo.nota)} · Recibo ${privado.recibo.id}`
      : "";
  }
  return { mostrarCarga, renderizar };
}
