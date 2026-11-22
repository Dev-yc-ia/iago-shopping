import { BASE } from "../config/ranking.js";
import { consultar, enviarAcao } from "../core/api.js";
import { carregarSessao } from "../core/sessao.js";
import { elemento } from "../core/dom.js";
const $ = (id) => document.getElementById(id);
async function carregar() {
  $("tentar").hidden = true;
  try {
    await carregarSessao();
    const dados = await consultar("api/usuarios");
    $("usuarios").replaceChildren(
      ...dados.usuarios.map((juiz) => {
        const card = elemento("article", "", "conta-juiz");
        const botao = elemento("button", juiz.ativo ? "Desativar" : "Ativar");
        botao.type = "button";
        botao.addEventListener("click", async () => {
          botao.disabled = true;
          try {
            await enviarAcao(
              `api/usuarios/${juiz.id}`,
              { ativo: !juiz.ativo },
              "PATCH",
            );
            await carregar();
          } catch (erro) {
            $("feedback").textContent = erro.message;
            botao.disabled = false;
          }
        });
        card.append(
          elemento("strong", juiz.nome),
          elemento(
            "span",
            `${juiz.login} · ${juiz.ativo ? "Ativo" : "Inativo"}`,
          ),
          botao,
        );
        return card;
      }),
    );
    $("carga").textContent = dados.usuarios.length
      ? `${dados.usuarios.length} juízes cadastrados`
      : "Nenhum juiz cadastrado.";
  } catch (erro) {
    $("usuarios").replaceChildren();
    $("carga").textContent = erro.message;
    $("tentar").hidden = false;
    if (erro.status === 401) location.assign(new URL("login/", BASE));
  }
}
$("cadastro-juiz").addEventListener("submit", async (evento) => {
  evento.preventDefault();
  $("salvar").disabled = true;
  try {
    const resultado = await enviarAcao("api/usuarios", {
      nome: $("nome").value,
      login: $("login-juiz").value,
      senha: $("senha-juiz").value,
    });
    $("cadastro-juiz").reset();
    $("feedback").textContent = resultado.mensagem;
    await carregar();
  } catch (erro) {
    $("feedback").textContent = erro.message;
  } finally {
    $("salvar").disabled = false;
  }
});
$("tentar").addEventListener("click", carregar);
carregar();
