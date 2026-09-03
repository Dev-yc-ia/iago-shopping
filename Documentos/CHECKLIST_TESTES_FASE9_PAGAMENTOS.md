# Checklist de Testes - Fase 9 Pagamentos

## Escopo

Payment Engine com Mock local aprovado e Fase 9A preparada para Mercado Pago Sandbox.

## Fluxo base

- Criar pedido a partir do carrinho.
- Abrir `pedidos.html`.
- Escolher método: Pix, cartão de débito ou cartão de crédito.
- Iniciar pagamento.
- Aguardar o processamento automático do Mock Provider.
- Confirmar atualização do pedido, pagamento, eventos, logs, e-mails simulados e estoque.

## Cenários obrigatórios

| Cenário | Ação | Resultado esperado |
|---|---|---|
| Aprovação | Configurar `sempre_aprovar` e iniciar pagamento | Pedido fica com pagamento aprovado e estoque baixa uma única vez. |
| Recusa | Configurar `sempre_recusar` e iniciar pagamento | Pedido registra recusa e estoque não baixa para pedidos novos. |
| Timeout | Configurar `timeout` e iniciar pagamento | Pedido permanece aguardando confirmação, com erro técnico registrado. |
| Expiração | Configurar `expirar` e iniciar pagamento Pix | Pagamento/Pix expira e pedido não baixa estoque. |
| Aleatório | Configurar `aleatorio` e iniciar múltiplas tentativas | Provider alterna resultados sem intervenção manual do cliente. |
| Atraso | Ajustar `atraso_ms` e iniciar pagamento | Frontend mostra `Processando pagamento` durante o período configurado. |
| Abandono | Iniciar pagamento e sair antes do retorno | Pedido permanece pendente até novo processamento/retorno de provider. |
| Duplicidade | Clicar para iniciar pagamento mais de uma vez | Engine reutiliza tentativa pendente ou bloqueia pedido aprovado. |
| Concorrência de estoque | Dois pedidos tentam pagar o último saldo | Só o primeiro aprovado baixa estoque; o segundo recebe erro de estoque insuficiente. |
| Reprocessamento | Processar aprovado duas vezes | Segunda aprovação não duplica baixa de estoque. |
| E-mails | Processar cada cenário | Fila `shopping_email_fila` recebe mensagens para cliente e admin. |
| Eventos | Processar cada cenário | `shopping_pagamento_eventos` registra o evento correspondente. |
| Logs | Processar cada cenário | `shopping_pagamento_logs` registra o processamento. |
| Admin | Abrir painel admin | Pedidos e pagamentos aparecem com status e contadores. |

## Configuracao do Mock Provider

Executar como administrador pelo SQL Editor quando quiser trocar o cenario:

```sql
select public.shopping_pagamento_mock_configurar('sempre_aprovar', 3500, 9000, 300000);
select public.shopping_pagamento_mock_configurar('sempre_recusar', 3500, 9000, 300000);
select public.shopping_pagamento_mock_configurar('aleatorio', 3500, 9000, 300000);
select public.shopping_pagamento_mock_configurar('timeout', 3500, 9000, 300000);
select public.shopping_pagamento_mock_configurar('expirar', 3500, 9000, 300000);
```

## Observações para gateway real

- Mercado Pago Checkout Transparente usa o mesmo contrato do Payment Engine.
- Webhooks chamam o processamento de status do provider, sem aprovação manual no frontend.
- A troca de provedor ocorre por configuração, sem reescrever regra de pedido, estoque, auditoria, eventos ou e-mails.

## Fase 9A - Mercado Pago Sandbox

### Configuração local necessária

No `.env`, configurar as chaves de teste:

```text
PAYMENT_PROVIDER=mercado_pago_sandbox
MERCADO_PAGO_ACCESS_TOKEN=TEST-...
MERCADO_PAGO_PUBLIC_KEY=TEST-...
MERCADO_PAGO_WEBHOOK_SECRET=...
MERCADO_PAGO_NOTIFICATION_URL=https://sua-url-publica/api/payments/webhooks/mercado-pago
SUPABASE_SERVICE_ROLE_KEY=...
```

Para voltar ao fluxo aprovado de simulação local:

```text
PAYMENT_PROVIDER=mock
```

### SQL obrigatório

Aplicar no Supabase, nesta ordem:

1. `sql/migrations/20260828_008_fase9_pagamentos.sql`
2. `sql/migrations/20260828_009_fase9_pagamentos_rpc_compat.sql`
3. `sql/migrations/20260829_010_fase9_pagamentos_mock_automatico.sql`
4. `sql/migrations/20260829_011_fase9a_mercado_pago_sandbox.sql`

### Validações 9A

| Cenário | Ação | Resultado esperado |
|---|---|---|
| Engine Sandbox | Abrir `/api/payments/engine` com `PAYMENT_PROVIDER=mercado_pago_sandbox` | Retorna provider `mercado_pago`, modo `sandbox`, public key e métodos Pix/débito/crédito. |
| Pix Sandbox | Criar pedido, escolher Pix e iniciar pagamento | Aparece QR Code oficial, copia e cola e status pendente. |
| Pix aprovado | Pagar/aprovar no ambiente Sandbox ou receber webhook | Pedido fica aprovado, estoque baixa uma única vez, evento/log/e-mail são criados. |
| Pix expirado | Deixar Pix expirar ou simular status `expired` pelo provider | Pedido/pagamento ficam expirados e estoque não baixa. |
| Cartão aprovado | Usar cartão de teste aprovado no Brick | Pedido fica aprovado somente após retorno do provider/sincronização. |
| Cartão recusado | Usar cartão de teste recusado no Brick | Pagamento fica recusado, pedido registra recusa e estoque não baixa. |
| Webhook | Enviar notificação Sandbox do Mercado Pago | Endpoint `/api/payments/webhooks/mercado-pago` consulta o provider e aplica status via SQL. |
| Idempotência | Clicar/repetir criação com instabilidade de rede | `X-Idempotency-Key` evita duplicidade no provider e o SQL não duplica baixa de estoque. |
| Admin | Abrir painel administrativo | Pagamentos mostram provider, modo, provider ID, status externo, eventos e e-mails. |

## Fase 9B - Checkout Profissional

| Cenário | Ação | Resultado esperado |
|---|---|---|
| Fluxo principal | Finalizar carrinho com usuário logado | Sistema cria pedido e abre `checkout.html?pedido=...`. |
| Acesso direto | Abrir `checkout.html?pedido=...` sem login | Usuário é levado ao login e volta ao checkout após entrar. |
| Pedido inexistente | Abrir checkout com ID inválido | Tela mostra pedido não encontrado sem quebrar navegação. |
| Resumo | Abrir checkout de pedido válido | Mostra itens, subtotal, total e número do pedido. |
| Método Pix | Selecionar Pix e iniciar pagamento | Cria tentativa no provider ativo e exibe QR/copia e cola quando o Mercado Pago devolver esses dados. |
| Diagnóstico Pix | Abrir console do navegador após gerar Pix | Log `[IAGO Payment] Pix provider response` mostra se vieram provider ID, QR base64, copia e cola e expiração, sem expor chaves. |
| Copiar Pix | Clicar em `Copiar código Pix` | Código Pix é copiado para a área de transferência e o botão muda para `Código copiado`. |
| Contagem Pix | Gerar Pix com data de expiração | Checkout mostra `Expira em mm:ss` e muda para `PIX expirado` quando o prazo acaba. |
| Atualização automática | Manter Pix pendente aberto | Checkout consulta o provider em intervalo configurado. |
| Cancelar pagamento | Gerar Pix ou pagamento pendente e clicar `Cancelar pagamento` | A tentativa fica cancelada, o polling para, o pedido continua pendente e os métodos ficam liberados. |
| Histórico de cancelamento | Cancelar uma tentativa e abrir Admin Pagamentos | Tentativa cancelada continua registrada em `shopping_pagamentos`, eventos, logs e auditoria. |
| Cartão de débito | Selecionar débito | Payment Brick aparece com identidade visual escura do IAGO quando `MERCADO_PAGO_PUBLIC_KEY` está configurada. |
| Cartão de débito Sandbox | Validar lista de meios exibidos pelo Brick | O Sandbox pode mostrar apenas cartões/meios habilitados pela conta de teste; em produção a lista é controlada pelo Mercado Pago conforme configuração da conta. |
| Cartão de crédito | Selecionar crédito | Payment Brick aparece com identidade visual escura do IAGO e envia token ao backend, sem formulário caseiro. |
| Feedback cartão | Enviar cartão pelo Brick | Checkout informa processamento automático enquanto tokeniza, envia e aguarda confirmação do Mercado Pago. |
| Pedido aprovado | Provider retorna aprovado | Checkout mostra pagamento aprovado; pedidos também mostra status aprovado. |
| Pedido recusado | Provider retorna recusado | Checkout permite nova tentativa sem baixar estoque. |
| Histórico | Abrir `pedidos.html` | Pedido aparece como acompanhamento e oferece `Continuar pagamento`. |
| Regressão Mock | Voltar `PAYMENT_PROVIDER=mock` | Checkout ainda permite pagar em modo Mock automático. |

### Observações finais 9B

- A tela do cliente não possui botões manuais de aprovação, recusa, pendência ou expiração.
- A tela do cliente possui apenas `Cancelar pagamento`, que cancela a tentativa atual e nunca cancela o pedido inteiro.
- A aprovação do pedido continua dependendo exclusivamente do retorno confirmado pelo provider, via webhook ou sincronização.
- A personalização do Payment Brick foi feita por configuração do SDK; partes internas do iframe seguem limitações do próprio Mercado Pago.
- Se Pix não exibir QR/copia e cola, verificar primeiro o console do navegador e o log do backend para saber se o provider devolveu `qr_code_base64`, `qr_code`, `ticket_url` e `expiration_date`.

### Checklist final para producao Mercado Pago

| Item | Validacao |
|---|---|
| Access Token Producao | Trocar `MERCADO_PAGO_ACCESS_TOKEN` para chave de producao e reiniciar backend. |
| Public Key Producao | Trocar `MERCADO_PAGO_PUBLIC_KEY` para chave de producao e recarregar checkout. |
| Provider | Usar `PAYMENT_PROVIDER=mercado_pago_prod`. |
| Notification URL | Configurar URL publica HTTPS em `MERCADO_PAGO_NOTIFICATION_URL`. |
| Webhook | Confirmar que `/api/payments/webhooks/mercado-pago` recebe notificacoes reais. |
| SSL | Usar somente URL publica com HTTPS valido. |
| Polling | Confirmar sincronizacao automatica quando webhook atrasar. |
| Pix real | Gerar Pix, pagar, receber webhook e validar pedido aprovado. |
| Pix cancelado | Cancelar tentativa no checkout e confirmar que pedido continua pendente. |
| Pix expirado | Deixar expirar e confirmar que estoque nao baixa. |
| Credito aprovado | Usar cartao real/teste autorizado e validar baixa unica de estoque. |
| Credito recusado | Validar recusa sem baixa de estoque. |
| Debito aprovado | Validar disponibilidade de bandeiras habilitadas na conta Mercado Pago. |
| Estoque | Confirmar que baixa ocorre apenas depois de `approved`. |
| Logs | Conferir `shopping_pagamento_logs` e logs do backend sem chaves expostas. |
| Admin | Conferir pedidos, pagamentos, eventos e fila de e-mails simulada. |
| Reembolso manual | Testar uma vez no painel Mercado Pago e conferir impacto operacional. |
