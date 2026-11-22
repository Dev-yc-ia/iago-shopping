const botaoMenu = document.getElementById("menu-toggle");
const menu = document.getElementById("menu");
const telaDesktop = window.matchMedia("(min-width: 761px)");

function definirMenuAberto(aberto) {
  if (!botaoMenu || !menu) {
    return;
  }

  menu.classList.toggle("aberto", aberto);
  botaoMenu.setAttribute("aria-expanded", String(aberto));
  botaoMenu.textContent = aberto ? "Recolher menu" : "Abrir menu";
}

function alternarMenu() {
  const aberto = menu.classList.contains("aberto");
  definirMenuAberto(!aberto);
}

function ajustarMenuAoTamanhoDaTela() {
  definirMenuAberto(telaDesktop.matches);
}

ajustarMenuAoTamanhoDaTela();
telaDesktop.addEventListener("change", ajustarMenuAoTamanhoDaTela);
botaoMenu?.addEventListener("click", alternarMenu);
