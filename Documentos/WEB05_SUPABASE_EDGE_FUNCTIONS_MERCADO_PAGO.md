# WEB-05 - Supabase Edge Functions / Mercado Pago

## Status

Codigo preparado para deploy das Edge Functions de pagamento. Producao ainda depende das acoes manuais de deploy, cadastro de secrets e configuracao do webhook no Mercado Pago.

## Arquitetura

```text
GitHub Pages
  -> Supabase Edge Functions
  -> Mercado Pago
  -> RPCs Supabase do IAGO Shopping
```

O FastAPI permanece no repositorio como referencia funcional e compatibilidade local, mas nao e requisito do fluxo web de pagamento em producao apos a WEB-05.

## Edge Functions

```text
payment-engine          Equivalente a GET /api/payments/engine
payment-create          Equivalente a POST /api/payments/create
payment-sync            Equivalente a POST /api/payments/sync
payment-cancel          Equivalente a POST /api/payments/cancel
mercado-pago-webhook    Equivalente a POST /api/payments/webhooks/mercado-pago
```

As funcoes de usuario exigem JWT Supabase. O webhook aceita chamada externa, mas falha se a assinatura Mercado Pago nao for valida.

## Deploy

```bash
supabase login
supabase link --project-ref ualnmcvgddofqvijzfjt
supabase functions deploy payment-engine
supabase functions deploy payment-create
supabase functions deploy payment-sync
supabase functions deploy payment-cancel
supabase functions deploy mercado-pago-webhook
```

## Secrets

Cadastrar manualmente em Supabase Dashboard -> Edge Functions -> Secrets, ou via CLI:

```bash
supabase secrets set PAYMENT_PROVIDER="mercado_pago_prod"
supabase secrets set MERCADO_PAGO_PUBLIC_KEY="<public key da aplicacao Mercado Pago>"
supabase secrets set MERCADO_PAGO_ACCESS_TOKEN="<access token da aplicacao Mercado Pago>"
supabase secrets set MERCADO_PAGO_WEBHOOK_SECRET="<assinatura secreta do webhook Mercado Pago>"
supabase secrets set MERCADO_PAGO_NOTIFICATION_URL="https://ualnmcvgddofqvijzfjt.supabase.co/functions/v1/mercado-pago-webhook"
supabase secrets set MERCADO_PAGO_PAYMENT_EXPIRATION_MINUTES="30"
supabase secrets set MERCADO_PAGO_POLL_INTERVAL_MS="3000"
```

Nao cadastrar `MERCADO_PAGO_ACCESS_TOKEN`, `MERCADO_PAGO_WEBHOOK_SECRET` ou chave administrativa Supabase no frontend, em SQL ou em arquivo versionado.

## Webhook Mercado Pago

URL:

```text
https://ualnmcvgddofqvijzfjt.supabase.co/functions/v1/mercado-pago-webhook
```

No Mercado Pago Developers:

1. Abrir a aplicacao do IAGO Shopping.
2. Ir em Webhooks / notificacoes.
3. Selecionar modo Producao.
4. Trocar a URL para a Edge Function acima.
5. Selecionar o evento de pagamentos compativel.
6. Salvar.
7. Copiar a Assinatura Secreta.
8. Cadastrar a assinatura como `MERCADO_PAGO_WEBHOOK_SECRET` nas Secrets das Edge Functions.

## Validacao sem pagamento real

Antes de teste financeiro real:

```text
payment-engine nao retorna secrets
payment-create, payment-sync e payment-cancel rejeitam chamada sem JWT
mercado-pago-webhook rejeita assinatura ausente/invalida
frontend nao usa api.ia-go.api.br para pagamento em producao
RPCs de pedido, pagamento e estoque permanecem preservadas
```
