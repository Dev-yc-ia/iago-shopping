import { BASE } from "../config/ranking.js";
import { enviarAcao } from "../core/api.js";
import { carregarSessao } from "../core/sessao.js";
const form = document.getElementById("alterar-senha");
carregarSessao().then((sessao) => {
  if (sessao.trocar_senha)
    document.getElementById("obrigatoria").textContent =
      "Primeiro acesso: altere a senha antes de continuar.";
});
form.addEventListener("submit", async (evento) => {
  evento.preventDefault();
  const botao = document.getElementById("salvar");
  botao.disabled = true;
  try {
    await enviarAcao(
      "api/auth/senha",
      Object.fromEntries(
        ["atual", "nova", "confirmacao"].map((id) => [
          id,
          document.getElementById(id).value,
        ]),
      ),
    );
    form.reset();
    await carregarSessao();
    location.assign(BASE);
  } catch (erro) {
    document.getElementById("feedback").textContent = erro.message;
  } finally {
    botao.disabled = false;
  }
});
