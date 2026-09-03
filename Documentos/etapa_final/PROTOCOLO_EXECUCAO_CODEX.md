# PROTOCOLO_EXECUCAO_CODEX.md

# Protocolo Oficial de Exec'ucao do Codex - IAGO Shopping

Versao: 1.1

Projeto: IAGO Shopping

Foco atual: fechamento da Fase 9B - Pagamentos

---

## Objetivo

Este documento define o padrao de execucao tecnica para o IAGO Shopping.

O Codex deve atuar como executor tecnico da etapa solicitada, preservando a arquitetura existente e evitando expansao de escopo.

O objetivo da retomada atual e estabilizar o fluxo de pagamentos antes de iniciar Usuarios, Perfis, Area Administrativa, Dashboard ou qualquer modulo futuro.

---

## Regra Principal

Executar somente a fase solicitada.

Para a retomada atual, executar exclusivamente a Fase 9B - Pagamentos.

Nao iniciar, antecipar ou corrigir fora do escopo:

- Usuarios
- Perfis
- Funcionarios
- Parceiros
- Area Administrativa
- Dashboard
- Produtos
- Catalogo
- Carrinho
- Autenticacao
- Integracao com Pesquisa IAGO

---

## Ordem de Leitura Recomendada

Antes de alterar codigo, ler nesta ordem:

1. `PROTOCOLO_EXECUCAO_CODEX.md`
2. `CONTEXTO_PROJETO.md`
3. `PLANEJAMENTO_MVP.md`
4. Documento da fase atual: Fase 9B - Pagamentos
5. Apenas os arquivos diretamente relacionados ao problema em execucao

Evitar percorrer o projeto inteiro quando a tarefa puder ser resolvida com leitura direcionada.

---

## Papel do Codex

O Codex e responsavel por:

- entender o comportamento atual;
- localizar o trecho minimo necessario;
- corrigir bugs da fase atual;
- preservar padroes existentes;
- executar validacoes relacionadas;
- relatar arquivos alterados e testes executados.

O Codex nao deve:

- redesenhar arquitetura;
- trocar tecnologias;
- reestruturar pastas;
- refatorar por iniciativa propria;
- alterar layout aprovado fora dos pontos de pagamento;
- criar funcionalidades novas;
- mexer em modulos nao autorizados.

---

## Escopo Autorizado da Fase 9B

Somente estes arquivos podem sofrer alteracao, se necessario:

Frontend:

- `frontend/checkout.html`
- `frontend/features/checkout.js`
- `frontend/features/payments.js`
- `frontend/features/orders.js`
- `frontend/css/style.css`

Backend:

- `backend/services/mercado_pago.py`
- `backend/services/payment_engine.py`
- `backend/routers/payments.py`
- `backend/schemas/payments.py`

Banco:

- usar migrations existentes da Fase 9, 9A e 9B como referencia;
- nao criar nova migration sem necessidade tecnica clara;
- se uma nova migration for inevitavel, explicar antes o motivo e manter escopo estritamente ligado ao pagamento.

---

## Arquivos Sensíveis

Nunca ler, abrir, alterar, imprimir ou solicitar conteudo de:

- `.env`
- `secrets.toml`
- arquivos de credenciais
- chaves Mercado Pago
- chaves Supabase
- tokens
- senhas

Se houver erro de configuracao, informar somente quais variaveis parecem ausentes ou invalidas.

Credenciais devem ser trocadas apenas por configuracao, nunca por alteracao de codigo.

---

## Filosofia de Alteracao

Preferir:

- alterar funcoes existentes;
- modificar o menor trecho possivel;
- preservar nomenclatura atual;
- preservar estrutura atual;
- preservar comportamento aprovado;
- manter compatibilidade com Supabase, FastAPI e Mercado Pago ja implementados.

Evitar:

- reescrever arquivos completos;
- mover arquivos;
- renomear componentes;
- alterar contratos publicos sem necessidade;
- adicionar dependencias sem necessidade;
- mascarar erros do Mercado Pago ou do backend.

---

## Layout e UX

O layout geral do IAGO Shopping esta congelado.

Na Fase 9B, alteracoes visuais so sao permitidas quando estiverem diretamente ligadas a:

- tema escuro do Payment Brick;
- campos brancos do Mercado Pago;
- alinhamento das etapas do checkout;
- estados, botoes, textos, loading e mensagens do fluxo de pagamento.

Nao alterar identidade visual, catalogo, login, paginas institucionais ou componentes sem relacao com pagamento.

---

## Validacoes Obrigatorias da Fase 9B

Ao final, validar os fluxos relacionados ao que foi alterado:

- Pix criado;
- QR Code Pix exibido ou erro real documentado;
- Copia e Cola exibido ou erro real documentado;
- cancelamento Pix;
- nova tentativa apos cancelamento;
- expiracao;
- pagamento aprovado;
- pagamento recusado;
- cartao de debito;
- cartao de credito;
- Payment Brick em tema escuro;
- atualizacao sem reload manual;
- historico de pedidos atualizado;
- pedido sem duplicacao indevida.

Se alguma validacao depender de ambiente externo, Sandbox ou credencial, registrar a limitacao claramente.

---

## Resposta Esperada ao Final

Responder de forma objetiva:

## Fase

Concluida ou nao.

## Arquivos alterados

Lista objetiva.

## Testes executados

Comando e resultado.

## Observacoes

Pendencias, limites de Sandbox, configuracoes necessarias ou riscos.

## Proximo passo

Aguardar aprovacao do usuario antes de iniciar outra etapa.
