# CONTEXTO_PROJETO.md

# Contexto do Projeto - IAGO Shopping

Projeto: IAGO Shopping

Documento de retomada para execucao tecnica focada.

---

## Objetivo do Projeto

Construir o IAGO Shopping como plataforma propria de e-commerce para a comunidade do skate.

O Shopping e independente da Pesquisa IAGO.

A integracao com a Pesquisa IAGO deve acontecer futuramente apenas por `response_id` e regras explicitas de consentimento.

Nao copiar dados pessoais da Pesquisa para o Shopping sem necessidade, base legal e consentimento.

---

## Raiz do Projeto

Raiz local conhecida:

```text
C:\dev_yc\versionador_ambientes\ambiente_homologacao\iago_shopping
```

Estrutura principal:

- `backend/`
- `frontend/`
- `sql/`
- `tests/`
- `Documentos/`

---

## Estado Atual

O projeto ja avancou alem do contexto antigo de Fase 2.

Estado consolidado a partir do dump atual do projeto:

- frontend do Shopping implementado;
- backend FastAPI implementado;
- integracao Supabase existente;
- autenticacao Supabase existente;
- administracao e permissoes ja possuem base SQL/frontend;
- catalogo, produtos, estoque, carrinho e pedidos possuem implementacoes;
- pagamentos ja possuem arquitetura ampla implementada;
- Fase 9, 9A e 9B possuem migrations e codigo relacionados.

Foco atual:

```text
Fase 9B - Fechamento de Pagamentos
```

A Fase 9B nao e uma fase de criacao de modulo novo. E uma etapa de estabilizacao e fechamento do fluxo de pagamento.

---

## Funcionalidades de Pagamento Ja Existentes

Backend:

- FastAPI;
- Payment Engine;
- provedor mock;
- integracao Mercado Pago;
- criacao de pagamento;
- sincronizacao;
- consulta;
- webhook;
- cancelamento no backend;
- logs;
- integracao com RPCs Supabase.

Frontend:

- checkout;
- selecao de metodo;
- fluxo Pix;
- fluxo Cartao;
- Payment Brick;
- historico de pedidos;
- polling;
- expiracao;
- geracao de nova tentativa;
- atualizacao de status.

Banco:

- tabelas de pagamentos;
- eventos de pagamento;
- logs;
- funcoes RPC;
- configuracao nao sensivel de provider;
- baixa de estoque apos confirmacao;
- cancelamento de tentativa de pagamento na Fase 9B.

---

## Arquivos Relevantes Para Pagamentos

Frontend:

- `frontend/checkout.html`
- `frontend/features/checkout.js`
- `frontend/features/payments.js`
- `frontend/features/orders.js`
- `frontend/css/style.css`

Backend:

- `backend/routers/payments.py`
- `backend/services/mercado_pago.py`
- `backend/services/payment_engine.py`
- `backend/services/supabase_rpc.py`
- `backend/schemas/payments.py`
- `backend/config/settings.py`

SQL:

- `sql/migrations/20260828_008_fase9_pagamentos.sql`
- `sql/migrations/20260828_009_fase9_pagamentos_rpc_compat.sql`
- `sql/migrations/20260829_010_fase9_pagamentos_mock_automatico.sql`
- `sql/migrations/20260829_011_fase9a_mercado_pago_sandbox.sql`
- `sql/migrations/20260829_012_fase9b_cancelamento_pagamento.sql`

---

## Pontos Sensíveis de Configuracao

O backend possui configuracoes para:

- `PAYMENT_PROVIDER`
- `MERCADO_PAGO_ACCESS_TOKEN`
- `MERCADO_PAGO_PUBLIC_KEY`
- `MERCADO_PAGO_WEBHOOK_SECRET`
- `MERCADO_PAGO_NOTIFICATION_URL`
- `MERCADO_PAGO_PAYMENT_EXPIRATION_MINUTES`
- `MERCADO_PAGO_POLL_INTERVAL_MS`
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`

Nao ler valores reais dessas variaveis.

Se for necessario diagnosticar configuracao, usar somente diagnostico de presenca/ausencia, sem expor segredos.

---

## Problemas Conhecidos da Fase 9B

1. Botao de cancelamento Pix aparece de forma inconsistente.
2. QR Code Pix nao aparece; a interface mostra apenas `Aguardando codigo Pix do provider.`
3. Necessario confirmar se o Sandbox Mercado Pago gera QR Code e Copia e Cola no fluxo atual.
4. Necessario documentar troca Sandbox/Producao por configuracao, sem alterar codigo.
5. Fluxo completo precisa ser validado de ponta a ponta.
6. Fluxo recusado precisa permitir nova tentativa sem duplicar pedido.
7. Fluxo cancelado precisa cancelar Mercado Pago, cancelar Supabase e liberar nova tentativa sem reload.
8. Fluxo expirado precisa atualizar automaticamente e permitir novo Pix sem reload.
9. Payment Brick ainda possui componentes brancos.
10. Etapas superiores do checkout estao desalinhadas.
11. Checkout precisa de revisao de estados, textos, botoes, loading, polling e UX.

---

## O Que Nao Deve Ser Iniciado Agora

Nao iniciar:

- Usuarios;
- Perfis;
- Funcionarios;
- Parceiros;
- Area Administrativa;
- Dashboard;
- Produtos;
- Catalogo;
- Carrinho;
- Autenticacao;
- Integracao Pesquisa IAGO.

Esses temas ficam congelados ate aprovacao explicita.

---

## Criterio de Sucesso Atual

A Fase 9B so deve ser considerada concluida quando estiverem resolvidos ou claramente documentados:

- Pix;
- QR Code;
- Copia e Cola;
- cancelamento Pix;
- nova tentativa;
- expiracao;
- aprovacao;
- recusa;
- cartao de debito;
- cartao de credito;
- tema escuro do Payment Brick;
- preparacao para Producao;
- validacao em Homologacao;
- alinhamento visual do fluxo;
- ausencia de bugs conhecidos no checkout.
