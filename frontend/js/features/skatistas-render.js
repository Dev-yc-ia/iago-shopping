import { elemento } from "../core/dom.js";

const formatarData = (iso) => iso.split("-").reverse().join("/");

/** Somente nós textuais: nomes, escolas e demais valores nunca viram HTML. */
export function renderizarSkatistas(inscricoes, categorias, destino, editar) {
  const pessoas = new Map();
  for (const inscricao of inscricoes) {
    const chave = inscricao.skatista_id ?? inscricao.id;
    if (!pessoas.has(chave)) pessoas.set(chave, { ...inscricao, categorias: [] });
    pessoas.get(chave).categorias.push(inscricao.categoria_base);
  }
  destino.replaceChildren(
    ...Array.from(pessoas.values(), (item) => {
      const card = elemento("article", "", "painel ficha");
      card.append(elemento("h2", item.nome));
      const campos = [
        ["Escola", item.escola],
        ["Nascimento", formatarData(item.data_nascimento)],
        ["Ano", item.ano_nascimento],
        ["Sexo confirmado", item.sexo_confirmado],
        ["Categorias", categorias.filter(codigo => item.categorias.includes(codigo)).join(", ")],
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
