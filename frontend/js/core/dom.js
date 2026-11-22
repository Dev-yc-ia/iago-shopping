/** Cria conteúdo textual com segurança: nenhum valor do cadastro é interpretado como HTML. */
export function elemento(tag, texto = "", classe = "") {
  const node = document.createElement(tag);
  node.textContent = texto;
  if (classe) node.className = classe;
  return node;
}

export function opcoes(select, itens, selecionado = select.value) {
  select.replaceChildren(
    ...itens.map(({ valor, rotulo }) => {
      const option = elemento("option", rotulo);
      option.value = valor;
      return option;
    }),
  );
  if (itens.some((item) => item.valor === selecionado))
    select.value = selecionado;
}
