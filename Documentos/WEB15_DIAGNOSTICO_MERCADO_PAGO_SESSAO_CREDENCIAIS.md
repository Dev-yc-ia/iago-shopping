# WEB-15 - Diagnostico Mercado Pago, sessao e credenciais

Data: 2026-09-11

## A. Origem exata da mensagem

A mensagem `Token de sessão inválido.` foi localizada em:

- `backend/routers/payments.py`, funcao `_bearer_token`, quando o header `Authorization` nao esta no formato `Bearer <token>`.
- `supabase/functions/_shared/supabase.ts`, funcao `userSupabaseClient`, quando `supabase.auth.getUser(userJwt)` rejeita o JWT ou nao retorna usuario.

O checkout web de producao usa as Supabase Edge Functions, entao o ponto relevante para o Pix atual e `supabase/functions/_shared/supabase.ts`.

## B. Fluxo completo do request

Fluxo real do botao `Gerar Pix`:

`frontend/features/checkout.js` chama `startPayment`.

`frontend/features/payments.js` chama `createMercadoPagoPayment`.

`createMercadoPagoPayment` chama `edgePaymentRequest`.

`edgePaymentRequest` obtem a sessao Supabase e invoca a Edge Function `payment-create`.

`supabase/functions/payment-create/index.ts` valida provider, corpo da requisicao e sessao do usuario.

`userSupabaseClient` valida o JWT do comprador e cria um cliente Supabase com `Authorization: Bearer <JWT>`.

Depois disso, a funcao chama:

- `shopping_pagamento_checkout_context`
- `createMercadoPagoPayment`
- `shopping_pagamento_mercado_pago_registrar_checkout`
- `shopping_pagamento_mercado_pago_sincronizar_consulta`, quando ha status do provider

## C. Estado da sessao Supabase

O frontend ja exigia `session.access_token`, mas dependia do envio implicito do token por `supabase.functions.invoke`.

Correcao aplicada: `edgePaymentRequest` agora envia explicitamente:

`Authorization: Bearer ${session.access_token}`

Tambem foi adicionado log seguro de presenca de sessao/token, sem imprimir o JWT.

## D. Funcao de validacao JWT

A validacao central e `userSupabaseClient` em `supabase/functions/_shared/supabase.ts`.

Correcao aplicada: a validacao do JWT agora usa um cliente de autenticacao com `supabaseSecretKey()`, enquanto as RPCs continuam usando o cliente com o JWT do usuario. Isso separa validacao administrativa da execucao com permissoes do comprador.

## E. Fonte atual do MP Access Token

A fonte efetiva no fluxo de Edge Function e:

`Deno.env.get("MERCADO_PAGO_ACCESS_TOKEN")`

Origem operacional esperada: Supabase Edge Function Secret.

## F. Nome exato da configuracao

Nome esperado:

`MERCADO_PAGO_ACCESS_TOKEN`

Outros nomes pesquisados:

- `MERCADOPAGO_ACCESS_TOKEN`
- `MP_ACCESS_TOKEN`
- `MERCADO_PAGO_TOKEN`

Nenhum desses nomes alternativos e usado pelo fluxo atual.

## G. Fingerprint seguro

Por seguranca, o codigo persistente nao imprime prefixo, sufixo, hash ou tamanho do segredo. A instrumentacao mantida registra apenas:

- fonte logica: `edge-secret:MERCADO_PAGO_ACCESS_TOKEN`
- presenca
- ambiente provavel: `production`, `test` ou `unknown`
- se o valor muda apos `trim`

## H. Comparacao com `.env`, se possivel

Auditoria local sem expor valores:

- `.env` contem pares Mercado Pago TEST e producao.
- O ultimo par local e de producao.
- Nao foi detectada diferenca de whitespace nos valores locais.

A comparacao com Secrets reais da Edge Function precisa ser feita no ambiente Supabase, porque os Secrets remotos nao ficam visiveis no repositorio.

## I. Whitespace/formatação

Correcao aplicada: a leitura da Edge Function agora preserva o valor bruto para diagnostico de `same_after_trim`, mas continua usando o valor aparado para a chamada HTTP.

## J. PROD x TEST

Correcao aplicada: a Edge Function agora bloqueia mistura obvia:

- `PAYMENT_PROVIDER=mercado_pago_prod` com token `TEST`
- provider sandbox com token `APP_USR`

## K. Teste isolado Mercado Pago

Nao foi executado contra o provider neste ambiente, porque o runtime `deno` nao esta instalado localmente e a validacao real depende dos Secrets remotos da Edge Function.

O fluxo agora registra `[MP-05] provider_auth_start` e `[MP-06] provider_auth_status` quando a Edge Function chamar o Mercado Pago, sem expor segredo.

## L. Teste isolado Auth

Nao foi executado com um JWT real neste ambiente. A correcao adiciona logs `[AUTH-*]` suficientes para diferenciar:

- ausencia de header
- bearer extraido
- JWT validado
- JWT recusado pelo Auth provider

## M. Causa raiz

Causa raiz provavel identificada no codigo: o checkout dependia de envio implicito do JWT pelo cliente Supabase ao invocar Edge Functions. Quando a Edge Function recebia um bearer ausente/incorreto/inadequado, `userSupabaseClient` disparava a mensagem `Token de sessão inválido.` antes de chegar ao Mercado Pago.

O Mercado Pago nao era necessariamente chamado nesse cenario.

## N. Correcao aplicada

- Envio explicito do JWT no frontend ao chamar Edge Functions de pagamento.
- Validacao do JWT no backend Edge com cliente administrativo.
- Logs seguros e numerados em auth, pagamento e Mercado Pago.
- Validacao contra mistura TEST/PROD do Access Token.
- Teste estatico para preservar o comportamento.

## O. Arquivos alterados

- `frontend/features/payments.js`
- `supabase/functions/_shared/supabase.ts`
- `supabase/functions/_shared/mercado_pago.ts`
- `supabase/functions/payment-create/index.ts`
- `tests/test_phase9b_checkout_static.py`
- `Documentos/WEB15_DIAGNOSTICO_MERCADO_PAGO_SESSAO_CREDENCIAIS.md`

## P. Testes finais

Executado:

`python -m pytest`

Resultado:

`60 passed`

Observacao: o pytest emitiu aviso de cache por permissao de escrita em `.pytest_cache`, sem falha de teste.

## Q. Logs removidos

Nao foram adicionados logs com JWT completo, Access Token completo, refresh token, Authorization completo, hash, prefixo ou sufixo de segredo.

## R. Pendencias manuais

- Deploy das Edge Functions alteradas.
- Gerar um Pix com usuario logado em producao/homologacao.
- Confirmar nos logs se o fluxo chega em `[PAY-02]`, `[MP-05]` e `[MP-06]`.
- Validar no Supabase se os Secrets remotos usam `PAYMENT_PROVIDER=mercado_pago_prod` e `MERCADO_PAGO_ACCESS_TOKEN` de producao.

Nao declarar `WEB-15 - CAUSA RAIZ IDENTIFICADA E FLUXO MERCADO PAGO VALIDADO` ate o checkout real ser executado com sucesso no ambiente alvo.

## S. Diagnostico adicional do 401 em `payment-create`

Em 2026-09-11, o teste real confirmou que o frontend envia `Authorization: Bearer <JWT>` para:

`https://ualnmcvgddofqvijzfjt.supabase.co/functions/v1/payment-create`

Mesmo assim, `authClient.auth.getUser(userJwt)` retornou 401 pela propria Edge Function. A investigacao agora fica restrita ao helper:

`supabase/functions/_shared/supabase.ts`

Alteracao aplicada:

- log `[AUTH-CONFIG]` com `admin_key_source`, `supabase_url_present` e `project_ref`;
- log `[AUTH-03] jwt_validation_failed` com `message`, `status` e `code` reais retornados por `auth.getUser`;
- nenhum JWT, chave, prefixo, sufixo ou digest e registrado.

O comando minimo para publicar esta rodada de diagnostico e:

`supabase functions deploy payment-create --project-ref ualnmcvgddofqvijzfjt`

Como `supabase.ts` e compartilhado, as funcoes que tambem usam esse helper e devem ser redeployadas quando a correcao final for fechada sao:

- `payment-create`
- `payment-sync`
- `payment-cancel`
- `mercado-pago-webhook`

Para diagnosticar apenas o 401 atual do Pix, redeployar `payment-create` e suficiente.

Depois do deploy, coletar somente:

- `[AUTH-CONFIG]`
- `[AUTH-01]`
- `[AUTH-02]`
- `[AUTH-03]`
- `[AUTH-04]`, se houver sucesso

Nao enviar JWT nem chaves nos logs.

## T. Ajuste contra 401 do Edge Gateway

O teste real posterior mostrou que a chamada para `payment-create` tinha `Authorization: Bearer <user JWT>` e `apikey: sb_publishable_...`, mas os logs da funcao exibiam apenas `booted` e `shutdown`. Isso indica que o 401 pode estar sendo produzido pelo Edge Gateway antes do handler executar.

Configuracao auditada:

`supabase/config.toml`

Antes:

```ini
[functions.payment-create]
verify_jwt = true
```

Ajuste aplicado:

```ini
[functions.payment-create]
verify_jwt = false
```

A autenticacao nao foi removida. O handler continua chamando:

`userSupabaseClient(request)`

e essa funcao continua extraindo `Authorization: Bearer <JWT>` e validando o usuario antes de executar RPCs ou chamar Mercado Pago.

Motivo tecnico: com `verify_jwt=true`, a verificacao da plataforma acontece antes do codigo da Edge Function. Quando ela rejeita o token, nenhum log `[AUTH-*]` aparece. Com `verify_jwt=false`, o request chega ao handler e a validacao explicita passa a produzir logs seguros para diagnostico.

Deploy obrigatorio desta rodada:

```powershell
supabase functions deploy payment-create --project-ref ualnmcvgddofqvijzfjt
```

Deploy executado nesta rodada via `npx --yes supabase functions deploy payment-create --project-ref ualnmcvgddofqvijzfjt`.

Resultado informado pela CLI:

```json
{"project_ref":"ualnmcvgddofqvijzfjt","functions":["payment-create"],"message":"Deployed Functions."}
```

Apos o deploy, conferir no Dashboard se a data de atualizacao de `payment-create` mudou de `3 days ago` para poucos segundos/minutos. Em seguida:

1. sair da conta;
2. entrar novamente;
3. gerar Pix;
4. conferir Logs.

Criterio de sucesso inicial:

- `[AUTH-CONFIG]`
- `[AUTH-01]`
- `[AUTH-02]`
- `[AUTH-03]`

Se `[AUTH-03]` falhar, analisar `message`, `status` e `code`. Se `[AUTH-03]` for `ok`, continuar para `PAY-*` e depois `MP-*`.

## U. Alinhamento de Pix, cartao, sincronizacao e cancelamento

Depois do deploy de `payment-create` com `verify_jwt=false`, o Pix passou a funcionar. Isso confirmou que a falha anterior estava na validacao do Edge Gateway antes do handler.

O cancelamento ainda retornou 401 em:

`/functions/v1/payment-cancel`

Auditoria mostrou que:

```ini
[functions.payment-sync]
verify_jwt = true

[functions.payment-cancel]
verify_jwt = true
```

Como `payment-sync` e `payment-cancel` tambem validam o usuario dentro do handler via `userSupabaseClient(request)`, as tres funcoes de usuario Mercado Pago foram alinhadas:

```ini
[functions.payment-create]
verify_jwt = false

[functions.payment-sync]
verify_jwt = false

[functions.payment-cancel]
verify_jwt = false
```

Autenticacao mantida:

- `payment-create` chama `userSupabaseClient(request)`;
- `payment-sync` chama `userSupabaseClient(request)`;
- `payment-cancel` chama `userSupabaseClient(request)`.

Logs seguros adicionados:

- `PAY-SYNC-*`
- `PAY-CANCEL-*`

Deploy necessario para deixar todos os fluxos Mercado Pago no mesmo padrao:

```powershell
npx --yes supabase functions deploy payment-create --project-ref ualnmcvgddofqvijzfjt
npx --yes supabase functions deploy payment-sync --project-ref ualnmcvgddofqvijzfjt
npx --yes supabase functions deploy payment-cancel --project-ref ualnmcvgddofqvijzfjt
```

Deploy executado nesta rodada:

- `payment-create`: sem mudanca remota detectada, funcao ja estava publicada;
- `payment-sync`: publicada com sucesso;
- `payment-cancel`: publicada com sucesso.

Nenhuma credencial Mercado Pago foi alterada.
