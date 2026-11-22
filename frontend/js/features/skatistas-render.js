import { elemento } from "../core/dom.js";

const formatarData = (iso) => iso.split("-").reverse().join("/");

/** Somente nós textuais: nomes, escolas e demais valores nunca viram HTML. */
export function renderizarSkatistas(inscricoes, destino, editar) {
  destino.replaceChildren(
    ...inscricoes.map((item) => {
      const card = elemento("article", "", "painel ficha");
      card.append(elemento("h2", item.nome));
      const campos = [
        ["Escola", item.escola],
        ["Nascimento", formatarData(item.data_nascimento)],
        ["Ano", item.ano_nascimento],
        ["Sexo confirmado", item.sexo_confirmado],
        ["Categoria-base", item.categoria_base],
      ];
      const detalhes = elemento("dl");
      for (const [rotulo, valor] of campos)
        detalhes.append(elemento("dt", rotulo), elemento("dd", valor));
      const botao = elemento("button", "Editar");
      botao.type = "button";
      botao.setAttribute("aria-label", `Editar ${item.nome}`);
      botao.addEventListener("click", () => editar(item, botao));
      card.append(detalhes, botao);
      return card;
    }),
  );
}
