import { carregarSessao } from "../core/sessao.js";
import { enviarAcao, importarSkatistas, obterSkatistas } from "../core/api.js";
import { renderizarSkatistas } from "../features/skatistas-render.js";

const dom = Object.fromEntries(
  ["lista-skatistas", "carga", "tentar"].map((id) => [
    id,
    document.getElementById(id),
  ]),
);

async function carregar() {
  dom.carga.textContent = "Carregando credenciamento local…";
  dom.tentar.hidden = true;
  dom["lista-skatistas"].replaceChildren();
  try {
    await carregarSessao();
    const { inscricoes, categorias } = await obterSkatistas();
    cadastro.elements.categoria.replaceChildren(
      new Option("Selecione", ""),
      ...categorias.map(categoria => new Option(categoria, categoria)),
    );
    dom.carga.textContent = inscricoes.length
      ? `${inscricoes.length} inscrições`
      : "Cadastro vazio.";
    renderizarSkatistas(inscricoes, dom["lista-skatistas"]);
  } catch (erro) {
    dom.carga.textContent = erro.message;
    dom.tentar.hidden = false;
  }
}

const cadastro = document.getElementById("cadastro");
const importacao = document.getElementById("importacao");
const resultado = document.getElementById("resultado-cadastro");
const ano = document.getElementById("ano");
cadastro.elements.nascimento.addEventListener("input", () => {
  ano.value = cadastro.elements.nascimento.value.split("-")[0];
});
function aoEnviar(formulario, enviar) {
  formulario.addEventListener("submit", async (evento) => {
    evento.preventDefault();
    const campos = new FormData(formulario);
    const botao = formulario.querySelector("button");
    botao.disabled = true;
    try {
      const { incluidos, duplicados } = await enviar(campos);
      resultado.textContent = `${incluidos} incluídos, ${duplicados} já cadastrados.`;
      formulario.reset();
      if (formulario === cadastro) ano.value = "";
      await carregar();
    } catch (erro) {
      resultado.textContent = erro.message;
    } finally {
      botao.disabled = false;
    }
  });
}
aoEnviar(cadastro, campos => enviarAcao("api/skatistas", Object.fromEntries(campos)));
aoEnviar(importacao, campos => importarSkatistas(campos.get("arquivo")));
dom.tentar.addEventListener("click", carregar);
carregar();
