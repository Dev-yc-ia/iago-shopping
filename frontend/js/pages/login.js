import { BASE } from "../config/ranking.js";
import { enviarAcao } from "../core/api.js";
import { carregarSessao } from "../core/sessao.js";
const form = document.getElementById("login");
const feedback = document.getElementById("feedback");
form.addEventListener("submit", async (evento) => {
  evento.preventDefault();
  const botao = document.getElementById("entrar");
  botao.disabled = true;
  try {
    await enviarAcao("api/auth/login", {
      login: document.getElementById("login-nome").value,
      senha: document.getElementById("login-senha").value,
    });
    form.reset();
    const sessao = await carregarSessao();
    location.assign(
      new URL(sessao.trocar_senha ? "alterar-senha/" : "./", BASE),
    );
  } catch (erro) {
    feedback.textContent = erro.message;
  } finally {
    botao.disabled = false;
  }
});
