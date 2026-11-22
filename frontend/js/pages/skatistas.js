import { carregarSessao } from "../core/sessao.js";
import { enviarAcao, importarSkatistas, obterSkatistas, urlAvatar } from "../core/api.js";
import { renderizarSkatistas } from "../features/skatistas-render.js";

const lista = document.getElementById("lista-skatistas");
const carga = document.getElementById("carga");
const tentar = document.getElementById("tentar");
const cadastro = document.getElementById("cadastro");
const importacao = document.getElementById("importacao");
const resultado = document.getElementById("resultado-cadastro");
const ano = document.getElementById("ano");
const painel = cadastro.closest("details");
const titulo = painel.querySelector("summary");
const salvar = cadastro.querySelector('button[type="submit"]');
const cancelar = document.getElementById("cancelar-edicao");
const remover = document.getElementById("remover-foto");
const previa = document.getElementById("previa-foto");
const { nascimento, foto, foto_autorizada: autorizacao } = cadastro.elements;
const lado = 128;

let editando = null;
let botaoEdicao = null;
let fotoRemovida = false;
let imagem = null;
let revisao = 0;
let processando = false;
let enviando = false;

function atualizarAno() {
  ano.value = nascimento.value.split("-")[0];
}

function mostrarPrevia(src) {
  previa.hidden = !src;
  if (src) previa.src = src;
  else previa.removeAttribute("src");
}

function ajustarFoto(src = editando && urlAvatar(editando)) {
  foto.value = "";
  foto.setCustomValidity("");
  autorizacao.checked = false;
  autorizacao.required = false;
  remover.hidden = !src;
  fotoRemovida = false;
  imagem = null;
  revisao++;
  processando = false;
  salvar.disabled = enviando;
  mostrarPrevia(src);
}

function preencher(item = null, botao = null) {
  editando = item;
  botaoEdicao = botao;
  cadastro.reset();
  ajustarFoto();
  cancelar.hidden = !item;
  titulo.textContent = item ? "Editar skatista" : "Cadastrar skatista";
  salvar.textContent = item ? "Salvar alterações" : "Cadastrar";
  if (item) {
    cadastro.elements.nome.value = item.nome;
    cadastro.elements.escola.value = item.escola;
    nascimento.value = item.data_nascimento;
    cadastro.elements.sexo.value = item.sexo_confirmado;
    cadastro.elements.categoria.value = item.categoria_base;
    painel.open = true;
    cadastro.elements.nome.focus();
  }
  atualizarAno();
}

async function carregar() {
  carga.textContent = "Carregando credenciamento local.";
  tentar.hidden = true;
  try {
    await carregarSessao();
    const { inscricoes, categorias } = await obterSkatistas();
    const categoria = cadastro.elements.categoria;
    const selecionada = categoria.value;
    categoria.replaceChildren(
      new Option("Selecione", ""),
      ...categorias.map(valor => new Option(valor, valor)),
    );
    if (categorias.includes(selecionada)) categoria.value = selecionada;
    carga.textContent = inscricoes.length ? `${inscricoes.length} inscrições` : "Cadastro vazio.";
    renderizarSkatistas(inscricoes, lista, (item, botao) => {
      if (enviando) return;
      resultado.textContent = "";
      preencher(item, botao);
    });
  } catch (erro) {
    carga.textContent = erro.message;
    tentar.hidden = false;
  }
}

async function miniatura(arquivo) {
  if (arquivo.size > 5 * 1024 * 1024) throw new Error("A foto deve ter até 5 MiB.");
  const b = new Uint8Array(await arquivo.slice(0, 12).arrayBuffer());
  const assinatura = (...bytes) => bytes.every((valor, i) => b[i] === valor);
  const jpeg = assinatura(255, 216, 255);
  const png = assinatura(137, 80, 78, 71, 13, 10, 26, 10);
  const webp = assinatura(82, 73, 70, 70) && String.fromCharCode(...b.slice(8, 12)) === "WEBP";
  if (!jpeg && !png && !webp) throw new Error("Selecione uma imagem JPEG, PNG ou WebP.");
  const bitmap = await createImageBitmap(arquivo).catch(() => {
    throw new Error("Não foi possível abrir a imagem.");
  });
  try {
    if (bitmap.width > 4096 || bitmap.height > 4096) {
      throw new Error("A foto deve ter até 4096 pixels de largura e altura.");
    }
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = lado;
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    const recorte = Math.min(bitmap.width, bitmap.height);
    ctx.drawImage(bitmap, (bitmap.width - recorte) / 2, (bitmap.height - recorte) / 2,
      recorte, recorte, 0, 0, lado, lado);
    const pixels = ctx.getImageData(0, 0, lado, lado).data;
    let binario = "";
    for (let i = 0; i < pixels.length; i += 8192) {
      binario += String.fromCharCode(...pixels.subarray(i, i + 8192));
    }
    return { rgba: btoa(binario), src: canvas.toDataURL("image/png") };
  } finally {
    bitmap.close();
  }
}

foto.addEventListener("change", async () => {
  const arquivo = foto.files[0];
  if (!arquivo) {
    ajustarFoto();
    salvar.disabled = enviando;
    return;
  }
  const atual = ++revisao;
  imagem = null;
  processando = true;
  salvar.disabled = true;
  foto.setCustomValidity("");
  autorizacao.checked = false;
  autorizacao.required = true;
  remover.hidden = false;
  try {
    const nova = await miniatura(arquivo);
    if (atual !== revisao) return;
    fotoRemovida = false;
    imagem = nova.rgba;
    mostrarPrevia(nova.src);
    resultado.textContent = "";
  } catch (erro) {
    if (atual !== revisao) return;
    foto.setCustomValidity(erro.message);
    resultado.textContent = erro.message;
  } finally {
    if (atual === revisao) {
      processando = false;
      salvar.disabled = enviando;
    }
  }
});
previa.addEventListener("error", () => { previa.hidden = true; });
remover.addEventListener("click", () => {
  ajustarFoto(null);
  fotoRemovida = Boolean(editando?.avatar_versao);
  salvar.disabled = enviando;
});
cancelar.addEventListener("click", () => {
  if (enviando) return;
  const origem = botaoEdicao;
  preencher();
  salvar.disabled = false;
  painel.open = false;
  resultado.textContent = "";
  origem?.focus();
});
nascimento.addEventListener("input", atualizarAno);

cadastro.addEventListener("submit", async evento => {
  evento.preventDefault();
  if (processando || enviando) return;
  const campos = new FormData(cadastro);
  const dados = Object.fromEntries(
    ["nome", "escola", "nascimento", "sexo", "categoria"].map(nome => [nome, campos.get(nome)]),
  );
  if (imagem) Object.assign(dados, { foto_rgba: imagem, foto_autorizada: autorizacao.checked });
  else if (fotoRemovida) dados.foto_rgba = null;

  enviando = true;
  const controles = Array.from(cadastro.querySelectorAll("input,select,button"));
  for (const controle of controles) controle.disabled = true;
  try {
    const resposta = editando
      ? await enviarAcao("api/skatistas/" + editando.id, dados, "PATCH")
      : await enviarAcao("api/skatistas", dados);
    resultado.textContent = editando
      ? "Cadastro atualizado."
      : `${resposta.incluidos} incluídos, ${resposta.duplicados} já cadastrados.`;
    preencher();
    await carregar();
  } catch (erro) {
    resultado.textContent = erro.message;
  } finally {
    enviando = false;
    for (const controle of controles) controle.disabled = false;
  }
});

importacao.addEventListener("submit", async evento => {
  evento.preventDefault();
  const botao = importacao.querySelector("button");
  botao.disabled = true;
  try {
    const { incluidos, duplicados } = await importarSkatistas(importacao.elements.arquivo.files[0]);
    resultado.textContent = `${incluidos} incluídos, ${duplicados} já cadastrados.`;
    importacao.reset();
    await carregar();
  } catch (erro) {
    resultado.textContent = erro.message;
  } finally {
    botao.disabled = false;
  }
});
tentar.addEventListener("click", carregar);
carregar();
