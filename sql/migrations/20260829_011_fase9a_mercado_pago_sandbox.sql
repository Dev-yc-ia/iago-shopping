-- Fase 9A - Payment Engine profissional com Mercado Pago Sandbox.
--
-- Escopo:
-- - manter o Mock Provider existente;
-- - preparar Mercado Pago Sandbox/Producao sem armazenar credenciais no banco;
-- - registrar campos oficiais do provider, Pix, webhook, consultas e auditoria;
-- - garantir que estoque, pedido, eventos e e-mails mudem apenas por confirmacao do provider.

alter table public.shopping_pagamentos
  add column if not exists provider_mode text not null default 'mock',
  add column if not exists provider_payment_id text,
  add column if not exists provider_preference_id text,
  add column if not exists provider_transaction_id text,
  add column if not exists qr_code_base64 text,
  add column if not exists qr_code_url text,
  add column if not exists copia_cola text,
  add column if not exists external_reference text,
  add column if not exists payment_url text,
  add column if not exists expiration_date timestamptz,
  add column if not exists provider_status text,
  add column if not exists provider_payload jsonb not null default '{}'::jsonb,
  add column if not exists request_payload jsonb not null default '{}'::jsonb,
  add column if not exists response_payload jsonb not null default '{}'::jsonb,
  add column if not exists response_headers jsonb not null default '{}'::jsonb,
  add column if not exists webhook_payload_bruto jsonb not null default '{}'::jsonb,
  add column if not exists webhook_payload_tratado jsonb not null default '{}'::jsonb,
  add column if not exists tempo_resposta_ms integer,
  add column if not exists http_status integer,
  add column if not exists erro_tecnico text,
  add column if not exists erro_negocio text,
  add column if not exists webhook_recebido_em timestamptz,
  add column if not exists webhook_processado_em timestamptz,
  add column if not exists ultima_consulta_provider timestamptz,
  add column if not exists ultima_sincronizacao timestamptz,
  add column if not exists tentativas_consulta integer not null default 0,
  add column if not exists tentativas_webhook integer not null default 0;

create index if not exists idx_shopping_pagamentos_provider_payment
  on public.shopping_pagamentos (provider_payment_id)
  where provider_payment_id is not null;

create index if not exists idx_shopping_pagamentos_external_reference
  on public.shopping_pagamentos (external_reference)
  where external_reference is not null;

create index if not exists idx_shopping_pagamentos_provider_status
  on public.shopping_pagamentos (provider_mode, provider_status, criado_em desc);

create table if not exists public.shopping_pagamento_provider_config (
  id boolean primary key default true,
  provider text not null default 'mock',
  ativo boolean not null default true,
  observacao text,
  atualizado_em timestamptz not null default now(),
  constraint shopping_pagamento_provider_config_singleton check (id),
  constraint shopping_pagamento_provider_config_provider check (
    provider in ('mock', 'mercado_pago_sandbox', 'mercado_pago_prod')
  )
);

insert into public.shopping_pagamento_provider_config (id)
values (true)
on conflict (id) do nothing;

drop trigger if exists trg_shopping_pagamento_provider_config_touch on public.shopping_pagamento_provider_config;
create trigger trg_shopping_pagamento_provider_config_touch
before update on public.shopping_pagamento_provider_config
for each row execute function public.shopping_touch_atualizado_em();

alter table public.shopping_pagamento_provider_config enable row level security;

drop policy if exists shopping_pagamento_provider_config_select_admin on public.shopping_pagamento_provider_config;
create policy shopping_pagamento_provider_config_select_admin
on public.shopping_pagamento_provider_config
for select
to authenticated
using (public.shopping_is_admin(auth.uid()));

drop function if exists public.shopping_pagamento_provider_configurar(text, text);
create or replace function public.shopping_pagamento_provider_configurar(
  p_provider text,
  p_observacao text default null
)
returns public.shopping_pagamento_provider_config
language plpgsql
security definer
set search_path = public
as $$
declare
  v_perfil public.shopping_perfis := public.shopping_admin_assert_produtos_permitido();
  v_config public.shopping_pagamento_provider_config;
begin
  if p_provider not in ('mock', 'mercado_pago_sandbox', 'mercado_pago_prod') then
    raise exception 'Provider de pagamento invalido.';
  end if;

  insert into public.shopping_pagamento_provider_config (id, provider, observacao)
  values (true, p_provider, p_observacao)
  on conflict (id) do update
  set provider = excluded.provider,
      observacao = excluded.observacao,
      ativo = true
  returning * into v_config;

  insert into public.shopping_auditoria (
    ator_user_id,
    acao,
    tabela,
    registro_id,
    antes,
    depois,
    motivo
  )
  values (
    auth.uid(),
    'pagamento.provider.configurar',
    'shopping_pagamento_provider_config',
    null,
    null,
    to_jsonb(v_config),
    'Provider ativo do Payment Engine configurado para a Fase 9A.'
  );

  return v_config;
end;
$$;

drop function if exists public.shopping_pagamento_checkout_context(uuid);
create or replace function public.shopping_pagamento_checkout_context(
  p_pedido_id uuid
)
returns table (
  pedido_id uuid,
  numero bigint,
  user_id uuid,
  cliente_nome text,
  cliente_email text,
  total numeric,
  moeda text,
  pagamento_status public.shopping_status_pagamento,
  itens jsonb
)
language sql
stable
security definer
set search_path = public
as $$
  select
    sp.id,
    sp.numero,
    sp.user_id,
    sp.cliente_nome,
    sp.cliente_email,
    sp.total,
    sp.moeda,
    sp.pagamento_status,
    coalesce(si.itens, '[]'::jsonb) as itens
  from public.shopping_pedidos sp
  left join lateral (
    select jsonb_agg(
      jsonb_build_object(
        'nome', spi.nome,
        'sku', spi.sku,
        'quantidade', spi.quantidade,
        'preco_unitario', spi.preco_unitario,
        'subtotal', spi.subtotal
      )
      order by spi.criado_em, spi.id
    ) as itens
    from public.shopping_pedido_itens spi
    where spi.pedido_id = sp.id
  ) si on true
  where sp.id = p_pedido_id
    and sp.user_id = auth.uid();
$$;

drop function if exists public.shopping_pagamento_mercado_pago_registrar_checkout(
  uuid, text, text, text, text, text, text, text, text, text, timestamptz, text, text, jsonb, jsonb, jsonb, integer, integer, text, text
);
create or replace function public.shopping_pagamento_mercado_pago_registrar_checkout(
  p_pedido_id uuid,
  p_metodo text,
  p_provider_mode text,
  p_provider_payment_id text default null,
  p_provider_preference_id text default null,
  p_provider_transaction_id text default null,
  p_qr_code_base64 text default null,
  p_qr_code_url text default null,
  p_copia_cola text default null,
  p_external_reference text default null,
  p_payment_url text default null,
  p_expiration_date timestamptz default null,
  p_provider_status text default null,
  p_idempotency_key text default null,
  p_request_payload jsonb default '{}'::jsonb,
  p_response_payload jsonb default '{}'::jsonb,
  p_response_headers jsonb default '{}'::jsonb,
  p_tempo_resposta_ms integer default null,
  p_http_status integer default null,
  p_erro_tecnico text default null,
  p_erro_negocio text default null
)
returns public.shopping_pagamentos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := public.shopping_carrinho_assert_user();
  v_pedido public.shopping_pedidos;
  v_pagamento public.shopping_pagamentos;
  v_metodo public.shopping_metodo_pagamento;
  v_idempotency_key text;
  v_external_reference text;
begin
  if p_metodo not in ('pix', 'cartao_debito', 'cartao_credito') then
    raise exception 'Metodo de pagamento invalido.';
  end if;

  if p_provider_mode not in ('sandbox', 'prod') then
    raise exception 'Modo do Mercado Pago invalido.';
  end if;

  v_metodo := p_metodo::public.shopping_metodo_pagamento;

  select *
  into v_pedido
  from public.shopping_pedidos sp
  where sp.id = p_pedido_id
    and sp.user_id = v_user_id
  for update;

  if v_pedido.id is null then
    raise exception 'Pedido nao encontrado para pagamento.';
  end if;

  if v_pedido.pagamento_status = 'aprovado'::public.shopping_status_pagamento then
    raise exception 'Pedido ja possui pagamento aprovado.';
  end if;

  v_external_reference := coalesce(
    nullif(btrim(p_external_reference), ''),
    'mp_' || replace(gen_random_uuid()::text, '-', '')
  );
  v_idempotency_key := coalesce(
    nullif(btrim(p_idempotency_key), ''),
    'mercado_pago:' || p_provider_mode || ':' || v_pedido.id::text || ':' || v_metodo::text || ':' || v_external_reference
  );

  insert into public.shopping_pagamentos (
    pedido_id,
    user_id,
    provedor,
    metodo,
    status,
    valor,
    moeda,
    referencia_externa,
    idempotency_key,
    checkout_payload,
    expira_em,
    provider_mode,
    provider_payment_id,
    provider_preference_id,
    provider_transaction_id,
    qr_code_base64,
    qr_code_url,
    copia_cola,
    external_reference,
    payment_url,
    expiration_date,
    provider_status,
    provider_payload,
    request_payload,
    response_payload,
    response_headers,
    tempo_resposta_ms,
    http_status,
    erro_tecnico,
    erro_negocio,
    ultima_consulta_provider,
    ultima_sincronizacao
  )
  values (
    v_pedido.id,
    v_user_id,
    'mercado_pago'::public.shopping_provedor_pagamento,
    v_metodo,
    'pendente'::public.shopping_status_pagamento,
    v_pedido.total,
    v_pedido.moeda,
    v_external_reference,
    v_idempotency_key,
    jsonb_build_object('engine', 'mercado_pago', 'mode', p_provider_mode, 'method', v_metodo::text),
    p_expiration_date,
    p_provider_mode,
    p_provider_payment_id,
    p_provider_preference_id,
    p_provider_transaction_id,
    p_qr_code_base64,
    p_qr_code_url,
    p_copia_cola,
    v_external_reference,
    p_payment_url,
    p_expiration_date,
    p_provider_status,
    coalesce(p_response_payload, '{}'::jsonb),
    coalesce(p_request_payload, '{}'::jsonb),
    coalesce(p_response_payload, '{}'::jsonb),
    coalesce(p_response_headers, '{}'::jsonb),
    p_tempo_resposta_ms,
    p_http_status,
    p_erro_tecnico,
    p_erro_negocio,
    now(),
    now()
  )
  on conflict (idempotency_key) do update
  set provider_payment_id = excluded.provider_payment_id,
      provider_preference_id = excluded.provider_preference_id,
      provider_transaction_id = excluded.provider_transaction_id,
      qr_code_base64 = excluded.qr_code_base64,
      qr_code_url = excluded.qr_code_url,
      copia_cola = excluded.copia_cola,
      payment_url = excluded.payment_url,
      expiration_date = excluded.expiration_date,
      expira_em = excluded.expira_em,
      provider_status = excluded.provider_status,
      provider_payload = excluded.provider_payload,
      request_payload = excluded.request_payload,
      response_payload = excluded.response_payload,
      response_headers = excluded.response_headers,
      tempo_resposta_ms = excluded.tempo_resposta_ms,
      http_status = excluded.http_status,
      erro_tecnico = excluded.erro_tecnico,
      erro_negocio = excluded.erro_negocio,
      ultima_consulta_provider = now(),
      ultima_sincronizacao = now()
  returning * into v_pagamento;

  update public.shopping_pedidos
  set pagamento_status = 'pendente'::public.shopping_status_pagamento
  where id = v_pedido.id;

  perform public.shopping_pagamento_registrar_evento(
    v_pagamento.id,
    v_pedido.id,
    'payment.mercado_pago.checkout.created',
    v_pagamento.status,
    jsonb_build_object(
      'mode', p_provider_mode,
      'method', v_metodo::text,
      'provider_payment_id', p_provider_payment_id,
      'provider_status', p_provider_status,
      'external_reference', v_external_reference
    )
  );

  insert into public.shopping_auditoria (
    ator_user_id,
    acao,
    tabela,
    registro_id,
    antes,
    depois,
    motivo
  )
  values (
    auth.uid(),
    'pagamento.mercado_pago.registrar_checkout',
    'shopping_pagamentos',
    v_pagamento.id,
    null,
    to_jsonb(v_pagamento),
    'Checkout Mercado Pago registrado pela Fase 9A.'
  );

  return v_pagamento;
end;
$$;

drop function if exists public.shopping_pagamento_status_provider_para_interno(text);
create or replace function public.shopping_pagamento_status_provider_para_interno(
  p_provider_status text
)
returns public.shopping_status_pagamento
language sql
immutable
set search_path = public
as $$
  select case lower(coalesce(p_provider_status, ''))
    when 'approved' then 'aprovado'::public.shopping_status_pagamento
    when 'accredited' then 'aprovado'::public.shopping_status_pagamento
    when 'rejected' then 'recusado'::public.shopping_status_pagamento
    when 'cancelled' then 'cancelado'::public.shopping_status_pagamento
    when 'canceled' then 'cancelado'::public.shopping_status_pagamento
    when 'expired' then 'expirado'::public.shopping_status_pagamento
    else 'pendente'::public.shopping_status_pagamento
  end;
$$;

drop function if exists public.shopping_pagamento_aplicar_resultado_provider(uuid, public.shopping_status_pagamento, text, jsonb, jsonb);
create or replace function public.shopping_pagamento_aplicar_resultado_provider(
  p_pagamento_id uuid,
  p_resultado public.shopping_status_pagamento,
  p_evento_tipo text,
  p_payload_bruto jsonb default '{}'::jsonb,
  p_payload_tratado jsonb default '{}'::jsonb
)
returns public.shopping_pagamentos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pagamento public.shopping_pagamentos;
  v_pagamento_antes jsonb;
begin
  select *
  into v_pagamento
  from public.shopping_pagamentos sp
  where sp.id = p_pagamento_id
  for update;

  if v_pagamento.id is null then
    raise exception 'Pagamento nao encontrado para aplicar resultado do provider.';
  end if;

  if v_pagamento.status = 'aprovado'::public.shopping_status_pagamento
    and p_resultado = 'aprovado'::public.shopping_status_pagamento then
    return v_pagamento;
  end if;

  if v_pagamento.status = 'aprovado'::public.shopping_status_pagamento
    and p_resultado <> 'aprovado'::public.shopping_status_pagamento then
    perform public.shopping_pagamento_registrar_evento(
      v_pagamento.id,
      v_pagamento.pedido_id,
      coalesce(p_evento_tipo, 'payment.provider.ignored'),
      v_pagamento.status,
      coalesce(p_payload_tratado, '{}'::jsonb) || jsonb_build_object('ignored_reason', 'approved_payment_is_final')
    );
    return v_pagamento;
  end if;

  v_pagamento_antes := to_jsonb(v_pagamento);

  update public.shopping_pagamentos
  set status = p_resultado,
      erro_codigo = case
        when p_resultado in ('recusado'::public.shopping_status_pagamento, 'expirado'::public.shopping_status_pagamento, 'cancelado'::public.shopping_status_pagamento)
          then 'provider_' || p_resultado::text
        else null
      end,
      erro_mensagem = case
        when p_resultado = 'recusado'::public.shopping_status_pagamento then 'Pagamento recusado pelo provider.'
        when p_resultado = 'expirado'::public.shopping_status_pagamento then 'Pagamento expirado pelo provider.'
        when p_resultado = 'cancelado'::public.shopping_status_pagamento then 'Pagamento cancelado pelo provider.'
        else null
      end,
      webhook_payload_bruto = case
        when p_evento_tipo like '%webhook%' then coalesce(p_payload_bruto, '{}'::jsonb)
        else webhook_payload_bruto
      end,
      webhook_payload_tratado = case
        when p_evento_tipo like '%webhook%' then coalesce(p_payload_tratado, '{}'::jsonb)
        else webhook_payload_tratado
      end,
      webhook_recebido_em = case
        when p_evento_tipo like '%webhook%' then now()
        else webhook_recebido_em
      end,
      webhook_processado_em = case
        when p_evento_tipo like '%webhook%' then now()
        else webhook_processado_em
      end,
      tentativas_webhook = case
        when p_evento_tipo like '%webhook%' then tentativas_webhook + 1
        else tentativas_webhook
      end,
      processado_em = case
        when p_resultado = 'pendente'::public.shopping_status_pagamento then processado_em
        else coalesce(processado_em, now())
      end,
      provider_payload = provider_payload || coalesce(p_payload_tratado, '{}'::jsonb),
      ultima_sincronizacao = now()
  where id = v_pagamento.id
  returning * into v_pagamento;

  if p_resultado = 'aprovado'::public.shopping_status_pagamento then
    perform public.shopping_pagamento_baixar_estoque_pedido(v_pagamento.pedido_id);

    update public.shopping_pedidos
    set pagamento_status = 'aprovado'::public.shopping_status_pagamento,
        pagamento_confirmado_em = coalesce(v_pagamento.processado_em, now())
    where id = v_pagamento.pedido_id;
  elsif p_resultado in (
    'recusado'::public.shopping_status_pagamento,
    'expirado'::public.shopping_status_pagamento,
    'cancelado'::public.shopping_status_pagamento
  ) then
    update public.shopping_pedidos
    set pagamento_status = p_resultado
    where id = v_pagamento.pedido_id;

    perform public.shopping_pagamento_reverter_estoque_pedido(v_pagamento.pedido_id);
  else
    update public.shopping_pedidos
    set pagamento_status = 'pendente'::public.shopping_status_pagamento
    where id = v_pagamento.pedido_id;
  end if;

  perform public.shopping_pagamento_registrar_evento(
    v_pagamento.id,
    v_pagamento.pedido_id,
    coalesce(p_evento_tipo, 'payment.provider.result'),
    p_resultado,
    coalesce(p_payload_tratado, '{}'::jsonb)
  );

  perform public.shopping_pagamento_enfileirar_emails(v_pagamento.id, v_pagamento.pedido_id, p_resultado);

  insert into public.shopping_auditoria (
    ator_user_id,
    acao,
    tabela,
    registro_id,
    antes,
    depois,
    motivo
  )
  values (
    auth.uid(),
    coalesce(p_evento_tipo, 'pagamento.provider.resultado'),
    'shopping_pagamentos',
    v_pagamento.id,
    v_pagamento_antes,
    to_jsonb(v_pagamento),
    'Resultado de pagamento aplicado pelo Payment Engine da Fase 9A.'
  );

  return v_pagamento;
end;
$$;

drop function if exists public.shopping_pagamento_mercado_pago_sincronizar_consulta(uuid, text, jsonb, jsonb, integer, text, text);
create or replace function public.shopping_pagamento_mercado_pago_sincronizar_consulta(
  p_pagamento_id uuid,
  p_provider_status text,
  p_provider_payload jsonb default '{}'::jsonb,
  p_response_headers jsonb default '{}'::jsonb,
  p_http_status integer default null,
  p_erro_tecnico text default null,
  p_erro_negocio text default null
)
returns public.shopping_pagamentos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_pagamento public.shopping_pagamentos;
  v_resultado public.shopping_status_pagamento;
begin
  select *
  into v_pagamento
  from public.shopping_pagamentos sp
  where sp.id = p_pagamento_id
  for update;

  if v_pagamento.id is null then
    raise exception 'Pagamento nao encontrado para consulta ao provider.';
  end if;

  if v_user_id is not null
    and v_pagamento.user_id <> v_user_id
    and not public.shopping_is_admin(v_user_id) then
    raise exception 'Pagamento nao pertence ao usuario autenticado.';
  end if;

  v_resultado := public.shopping_pagamento_status_provider_para_interno(p_provider_status);

  update public.shopping_pagamentos
  set provider_status = p_provider_status,
      provider_payload = provider_payload || coalesce(p_provider_payload, '{}'::jsonb),
      response_payload = coalesce(p_provider_payload, '{}'::jsonb),
      response_headers = coalesce(p_response_headers, '{}'::jsonb),
      http_status = p_http_status,
      erro_tecnico = p_erro_tecnico,
      erro_negocio = p_erro_negocio,
      ultima_consulta_provider = now(),
      tentativas_consulta = tentativas_consulta + 1,
      ultima_sincronizacao = now()
  where id = v_pagamento.id;

  return public.shopping_pagamento_aplicar_resultado_provider(
    p_pagamento_id,
    v_resultado,
    'payment.mercado_pago.sync',
    coalesce(p_provider_payload, '{}'::jsonb),
    jsonb_build_object('provider_status', p_provider_status) || coalesce(p_provider_payload, '{}'::jsonb)
  );
end;
$$;

drop function if exists public.shopping_pagamento_mercado_pago_processar_webhook(text, text, jsonb, jsonb, jsonb);
create or replace function public.shopping_pagamento_mercado_pago_processar_webhook(
  p_provider_payment_id text,
  p_provider_status text,
  p_payload_bruto jsonb default '{}'::jsonb,
  p_payload_tratado jsonb default '{}'::jsonb,
  p_headers jsonb default '{}'::jsonb
)
returns public.shopping_pagamentos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pagamento public.shopping_pagamentos;
  v_resultado public.shopping_status_pagamento;
begin
  select *
  into v_pagamento
  from public.shopping_pagamentos sp
  where sp.provider_payment_id = p_provider_payment_id
     or sp.external_reference = p_provider_payment_id
  order by sp.criado_em desc
  limit 1
  for update;

  if v_pagamento.id is null then
    raise exception 'Pagamento Mercado Pago nao encontrado para webhook.';
  end if;

  v_resultado := public.shopping_pagamento_status_provider_para_interno(p_provider_status);

  update public.shopping_pagamentos
  set provider_status = p_provider_status,
      response_headers = coalesce(p_headers, '{}'::jsonb),
      webhook_payload_bruto = coalesce(p_payload_bruto, '{}'::jsonb),
      webhook_payload_tratado = coalesce(p_payload_tratado, '{}'::jsonb),
      webhook_recebido_em = now(),
      webhook_processado_em = now(),
      tentativas_webhook = tentativas_webhook + 1,
      ultima_sincronizacao = now()
  where id = v_pagamento.id;

  return public.shopping_pagamento_aplicar_resultado_provider(
    v_pagamento.id,
    v_resultado,
    'payment.mercado_pago.webhook',
    coalesce(p_payload_bruto, '{}'::jsonb),
    jsonb_build_object('provider_status', p_provider_status) || coalesce(p_payload_tratado, '{}'::jsonb)
  );
end;
$$;

drop function if exists public.shopping_pedidos_cliente_listar();
create or replace function public.shopping_pedidos_cliente_listar()
returns table (
  id uuid,
  numero bigint,
  status public.shopping_status_pedido,
  pagamento_status public.shopping_status_pagamento,
  pagamento_id uuid,
  pagamento_provedor public.shopping_provedor_pagamento,
  pagamento_metodo public.shopping_metodo_pagamento,
  pagamento_erro_codigo text,
  pagamento_erro_mensagem text,
  pagamento_provider_mode text,
  pagamento_provider_payment_id text,
  pagamento_provider_preference_id text,
  pagamento_provider_transaction_id text,
  pagamento_qr_code_base64 text,
  pagamento_qr_code_url text,
  pagamento_copia_cola text,
  pagamento_external_reference text,
  pagamento_payment_url text,
  pagamento_expiration_date timestamptz,
  pagamento_provider_status text,
  pagamento_ultima_sincronizacao timestamptz,
  total numeric,
  moeda text,
  itens jsonb,
  criado_em timestamptz,
  atualizado_em timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    sp.id,
    sp.numero,
    sp.status,
    sp.pagamento_status,
    spl.pagamento_id,
    spl.pagamento_provedor,
    spl.pagamento_metodo,
    spl.pagamento_erro_codigo,
    spl.pagamento_erro_mensagem,
    spl.pagamento_provider_mode,
    spl.pagamento_provider_payment_id,
    spl.pagamento_provider_preference_id,
    spl.pagamento_provider_transaction_id,
    spl.pagamento_qr_code_base64,
    spl.pagamento_qr_code_url,
    spl.pagamento_copia_cola,
    spl.pagamento_external_reference,
    spl.pagamento_payment_url,
    spl.pagamento_expiration_date,
    spl.pagamento_provider_status,
    spl.pagamento_ultima_sincronizacao,
    sp.total,
    sp.moeda,
    coalesce(si.itens, '[]'::jsonb) as itens,
    sp.criado_em,
    sp.atualizado_em
  from public.shopping_pedidos sp
  left join lateral (
    select
      pg.id as pagamento_id,
      pg.provedor as pagamento_provedor,
      pg.metodo as pagamento_metodo,
      pg.erro_codigo as pagamento_erro_codigo,
      pg.erro_mensagem as pagamento_erro_mensagem,
      pg.provider_mode as pagamento_provider_mode,
      pg.provider_payment_id as pagamento_provider_payment_id,
      pg.provider_preference_id as pagamento_provider_preference_id,
      pg.provider_transaction_id as pagamento_provider_transaction_id,
      pg.qr_code_base64 as pagamento_qr_code_base64,
      pg.qr_code_url as pagamento_qr_code_url,
      pg.copia_cola as pagamento_copia_cola,
      pg.external_reference as pagamento_external_reference,
      pg.payment_url as pagamento_payment_url,
      pg.expiration_date as pagamento_expiration_date,
      pg.provider_status as pagamento_provider_status,
      pg.ultima_sincronizacao as pagamento_ultima_sincronizacao
    from public.shopping_pagamentos pg
    where pg.pedido_id = sp.id
    order by pg.criado_em desc
    limit 1
  ) spl on true
  left join lateral (
    select jsonb_agg(
      jsonb_build_object(
        'item_id', spi.id,
        'produto_id', spi.produto_id,
        'sku', spi.sku,
        'nome', spi.nome,
        'marca', spi.marca,
        'categoria', spi.categoria,
        'imagem_url', spi.imagem_url,
        'quantidade', spi.quantidade,
        'preco_unitario', spi.preco_unitario,
        'subtotal', spi.subtotal
      )
      order by spi.criado_em, spi.id
    ) as itens
    from public.shopping_pedido_itens spi
    where spi.pedido_id = sp.id
  ) si on true
  where sp.user_id = auth.uid()
  order by sp.criado_em desc, sp.numero desc;
$$;

drop function if exists public.shopping_admin_listar_pedidos();
create or replace function public.shopping_admin_listar_pedidos()
returns table (
  id uuid,
  numero bigint,
  status public.shopping_status_pedido,
  pagamento_status public.shopping_status_pagamento,
  pagamento_id uuid,
  pagamento_provedor public.shopping_provedor_pagamento,
  pagamento_metodo public.shopping_metodo_pagamento,
  pagamento_erro_codigo text,
  pagamento_erro_mensagem text,
  pagamento_provider_mode text,
  pagamento_provider_payment_id text,
  pagamento_provider_status text,
  cliente_nome text,
  cliente_email text,
  total numeric,
  moeda text,
  itens jsonb,
  criado_em timestamptz,
  atualizado_em timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_perfil public.shopping_perfis := public.shopping_admin_assert_produtos_permitido();
begin
  return query
  select
    sp.id,
    sp.numero,
    sp.status,
    sp.pagamento_status,
    spl.pagamento_id,
    spl.pagamento_provedor,
    spl.pagamento_metodo,
    spl.pagamento_erro_codigo,
    spl.pagamento_erro_mensagem,
    spl.pagamento_provider_mode,
    spl.pagamento_provider_payment_id,
    spl.pagamento_provider_status,
    sp.cliente_nome,
    sp.cliente_email,
    sp.total,
    sp.moeda,
    coalesce(si.itens, '[]'::jsonb) as itens,
    sp.criado_em,
    sp.atualizado_em
  from public.shopping_pedidos sp
  left join lateral (
    select
      pg.id as pagamento_id,
      pg.provedor as pagamento_provedor,
      pg.metodo as pagamento_metodo,
      pg.erro_codigo as pagamento_erro_codigo,
      pg.erro_mensagem as pagamento_erro_mensagem,
      pg.provider_mode as pagamento_provider_mode,
      pg.provider_payment_id as pagamento_provider_payment_id,
      pg.provider_status as pagamento_provider_status
    from public.shopping_pagamentos pg
    where pg.pedido_id = sp.id
    order by pg.criado_em desc
    limit 1
  ) spl on true
  left join lateral (
    select jsonb_agg(
      jsonb_build_object(
        'item_id', spi.id,
        'sku', spi.sku,
        'nome', spi.nome,
        'marca', spi.marca,
        'categoria', spi.categoria,
        'quantidade', spi.quantidade,
        'preco_unitario', spi.preco_unitario,
        'subtotal', spi.subtotal
      )
      order by spi.criado_em, spi.id
    ) as itens
    from public.shopping_pedido_itens spi
    where spi.pedido_id = sp.id
  ) si on true
  order by sp.criado_em desc, sp.numero desc;
end;
$$;

drop function if exists public.shopping_admin_listar_pagamentos();
create or replace function public.shopping_admin_listar_pagamentos()
returns table (
  id uuid,
  pedido_id uuid,
  pedido_numero bigint,
  cliente_nome text,
  cliente_email text,
  provedor public.shopping_provedor_pagamento,
  provider_mode text,
  provider_payment_id text,
  provider_status text,
  metodo public.shopping_metodo_pagamento,
  status public.shopping_status_pagamento,
  erro_codigo text,
  erro_mensagem text,
  valor numeric,
  moeda text,
  referencia_externa text,
  eventos integer,
  emails integer,
  criado_em timestamptz,
  atualizado_em timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_perfil public.shopping_perfis := public.shopping_admin_assert_produtos_permitido();
begin
  return query
  select
    pg.id,
    pg.pedido_id,
    sp.numero,
    sp.cliente_nome,
    sp.cliente_email,
    pg.provedor,
    pg.provider_mode,
    pg.provider_payment_id,
    pg.provider_status,
    pg.metodo,
    pg.status,
    pg.erro_codigo,
    pg.erro_mensagem,
    pg.valor,
    pg.moeda,
    pg.referencia_externa,
    coalesce(pe.total_eventos, 0)::integer as eventos,
    coalesce(ef.total_emails, 0)::integer as emails,
    pg.criado_em,
    pg.atualizado_em
  from public.shopping_pagamentos pg
  join public.shopping_pedidos sp on sp.id = pg.pedido_id
  left join lateral (
    select count(*) as total_eventos
    from public.shopping_pagamento_eventos pge
    where pge.pagamento_id = pg.id
  ) pe on true
  left join lateral (
    select count(*) as total_emails
    from public.shopping_email_fila sef
    where sef.pagamento_id = pg.id
  ) ef on true
  order by pg.criado_em desc;
end;
$$;

revoke all on public.shopping_pagamento_provider_config from anon, authenticated;
grant select on public.shopping_pagamento_provider_config to authenticated;

revoke all on function public.shopping_pagamento_provider_configurar(text, text) from public, anon, authenticated;
revoke all on function public.shopping_pagamento_checkout_context(uuid) from public, anon, authenticated;
revoke all on function public.shopping_pagamento_mercado_pago_registrar_checkout(uuid, text, text, text, text, text, text, text, text, text, text, timestamptz, text, text, jsonb, jsonb, jsonb, integer, integer, text, text) from public, anon, authenticated;
revoke all on function public.shopping_pagamento_status_provider_para_interno(text) from public, anon, authenticated;
revoke all on function public.shopping_pagamento_aplicar_resultado_provider(uuid, public.shopping_status_pagamento, text, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.shopping_pagamento_mercado_pago_sincronizar_consulta(uuid, text, jsonb, jsonb, integer, text, text) from public, anon, authenticated;
revoke all on function public.shopping_pagamento_mercado_pago_processar_webhook(text, text, jsonb, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.shopping_pedidos_cliente_listar() from public, anon, authenticated;
revoke all on function public.shopping_admin_listar_pedidos() from public, anon, authenticated;
revoke all on function public.shopping_admin_listar_pagamentos() from public, anon, authenticated;

grant execute on function public.shopping_pagamento_provider_configurar(text, text) to authenticated;
grant execute on function public.shopping_pagamento_checkout_context(uuid) to authenticated;
grant execute on function public.shopping_pagamento_mercado_pago_registrar_checkout(uuid, text, text, text, text, text, text, text, text, text, text, timestamptz, text, text, jsonb, jsonb, jsonb, integer, integer, text, text) to authenticated;
grant execute on function public.shopping_pagamento_mercado_pago_sincronizar_consulta(uuid, text, jsonb, jsonb, integer, text, text) to authenticated;
grant execute on function public.shopping_pedidos_cliente_listar() to authenticated;
grant execute on function public.shopping_admin_listar_pedidos() to authenticated;
grant execute on function public.shopping_admin_listar_pagamentos() to authenticated;

grant execute on function public.shopping_pagamento_status_provider_para_interno(text) to service_role;
grant execute on function public.shopping_pagamento_aplicar_resultado_provider(uuid, public.shopping_status_pagamento, text, jsonb, jsonb) to service_role;
grant execute on function public.shopping_pagamento_mercado_pago_sincronizar_consulta(uuid, text, jsonb, jsonb, integer, text, text) to service_role;
grant execute on function public.shopping_pagamento_mercado_pago_processar_webhook(text, text, jsonb, jsonb, jsonb) to service_role;

comment on table public.shopping_pagamento_provider_config is
  'Configuracao nao sensivel do provider ativo do Payment Engine. Credenciais ficam apenas no .env do backend.';

comment on function public.shopping_pagamento_checkout_context(uuid) is
  'Contexto seguro do pedido usado pelo backend para criar pagamento em provider externo.';

comment on function public.shopping_pagamento_mercado_pago_registrar_checkout(uuid, text, text, text, text, text, text, text, text, text, text, timestamptz, text, text, jsonb, jsonb, jsonb, integer, integer, text, text) is
  'Registra no SQL a tentativa criada no Mercado Pago Sandbox/Producao, incluindo Pix, idempotencia e payloads de auditoria.';

comment on function public.shopping_pagamento_mercado_pago_sincronizar_consulta(uuid, text, jsonb, jsonb, integer, text, text) is
  'Sincroniza consulta backend ao Mercado Pago e aplica resultado como retorno de provider.';

comment on function public.shopping_pagamento_mercado_pago_processar_webhook(text, text, jsonb, jsonb, jsonb) is
  'Aplica confirmacao automatica recebida por webhook Mercado Pago.';

notify pgrst, 'reload schema';
