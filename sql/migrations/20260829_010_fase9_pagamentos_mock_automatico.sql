-- Fase 9 - Pagamento mock automatico em fluxo semelhante a producao.
--
-- Escopo:
-- - remove a necessidade de aprovacao manual pelo cliente;
-- - cria configuracao do Mock Provider por cenario;
-- - processa a tentativa por uma RPC unica do provider;
-- - mantem estoque, pedido, eventos, logs, auditoria e e-mails na camada SQL.

create table if not exists public.shopping_pagamento_mock_config (
  id boolean primary key default true,
  cenario text not null default 'sempre_aprovar',
  atraso_ms integer not null default 3500,
  timeout_ms integer not null default 9000,
  expiracao_ms integer not null default 300000,
  atualizado_em timestamptz not null default now(),
  constraint shopping_pagamento_mock_config_singleton check (id),
  constraint shopping_pagamento_mock_config_cenario check (
    cenario in (
      'sempre_aprovar',
      'sempre_recusar',
      'aleatorio',
      'timeout',
      'expirar'
    )
  ),
  constraint shopping_pagamento_mock_config_atraso_range check (atraso_ms between 0 and 30000),
  constraint shopping_pagamento_mock_config_timeout_range check (timeout_ms between 1000 and 120000),
  constraint shopping_pagamento_mock_config_expiracao_range check (expiracao_ms between 1000 and 3600000)
);

insert into public.shopping_pagamento_mock_config (id)
values (true)
on conflict (id) do nothing;

drop trigger if exists trg_shopping_pagamento_mock_config_touch on public.shopping_pagamento_mock_config;
create trigger trg_shopping_pagamento_mock_config_touch
before update on public.shopping_pagamento_mock_config
for each row execute function public.shopping_touch_atualizado_em();

alter table public.shopping_pagamento_mock_config enable row level security;

drop policy if exists shopping_pagamento_mock_config_select_admin on public.shopping_pagamento_mock_config;
create policy shopping_pagamento_mock_config_select_admin
on public.shopping_pagamento_mock_config
for select
to authenticated
using (public.shopping_is_admin(auth.uid()));

drop function if exists public.shopping_pagamento_mock_configurar(text, integer, integer, integer);

create or replace function public.shopping_pagamento_mock_configurar(
  p_cenario text,
  p_atraso_ms integer default null,
  p_timeout_ms integer default null,
  p_expiracao_ms integer default null
)
returns public.shopping_pagamento_mock_config
language plpgsql
security definer
set search_path = public
as $$
declare
  v_perfil public.shopping_perfis := public.shopping_admin_assert_produtos_permitido();
  v_config public.shopping_pagamento_mock_config;
begin
  if p_cenario not in ('sempre_aprovar', 'sempre_recusar', 'aleatorio', 'timeout', 'expirar') then
    raise exception 'Cenario mock invalido.';
  end if;

  insert into public.shopping_pagamento_mock_config (
    id,
    cenario,
    atraso_ms,
    timeout_ms,
    expiracao_ms
  )
  values (
    true,
    p_cenario,
    coalesce(p_atraso_ms, 3500),
    coalesce(p_timeout_ms, 9000),
    coalesce(p_expiracao_ms, 300000)
  )
  on conflict (id) do update
  set cenario = excluded.cenario,
      atraso_ms = excluded.atraso_ms,
      timeout_ms = excluded.timeout_ms,
      expiracao_ms = excluded.expiracao_ms
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
    'pagamento.mock.configurar',
    'shopping_pagamento_mock_config',
    null,
    null,
    to_jsonb(v_config),
    'Configuracao do Mock Provider de pagamentos da Fase 9.'
  );

  return v_config;
end;
$$;

drop function if exists public.shopping_pagamento_mock_processar_rpc(uuid);

create or replace function public.shopping_pagamento_mock_processar_rpc(
  p_pagamento_id uuid
)
returns public.shopping_pagamentos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := public.shopping_carrinho_assert_user();
  v_pagamento public.shopping_pagamentos;
  v_config public.shopping_pagamento_mock_config;
  v_resultado public.shopping_status_pagamento := 'aprovado'::public.shopping_status_pagamento;
  v_payload jsonb;
  v_random numeric;
begin
  select *
  into v_pagamento
  from public.shopping_pagamentos sp
  where sp.id = p_pagamento_id
    and (
      sp.user_id = v_user_id
      or public.shopping_is_admin(v_user_id)
    )
  for update;

  if v_pagamento.id is null then
    raise exception 'Pagamento nao encontrado para processamento.';
  end if;

  if v_pagamento.provedor <> 'mock'::public.shopping_provedor_pagamento then
    raise exception 'Somente pagamentos mock podem ser processados pelo Mock Provider.';
  end if;

  if v_pagamento.status = 'aprovado'::public.shopping_status_pagamento then
    return v_pagamento;
  end if;

  if v_pagamento.status not in (
    'criado'::public.shopping_status_pagamento,
    'pendente'::public.shopping_status_pagamento
  ) then
    return v_pagamento;
  end if;

  select *
  into v_config
  from public.shopping_pagamento_mock_config
  where id = true;

  if v_config.id is null then
    insert into public.shopping_pagamento_mock_config (id)
    values (true)
    on conflict (id) do nothing;

    select *
    into v_config
    from public.shopping_pagamento_mock_config
    where id = true;
  end if;

  if v_config.cenario = 'sempre_recusar' then
    v_resultado := 'recusado'::public.shopping_status_pagamento;
  elsif v_config.cenario = 'timeout' then
    v_resultado := 'pendente'::public.shopping_status_pagamento;
  elsif v_config.cenario = 'expirar' then
    v_resultado := 'expirado'::public.shopping_status_pagamento;
  elsif v_config.cenario = 'aleatorio' then
    v_random := random();
    v_resultado := case
      when v_random < 0.65 then 'aprovado'::public.shopping_status_pagamento
      when v_random < 0.85 then 'recusado'::public.shopping_status_pagamento
      else 'expirado'::public.shopping_status_pagamento
    end;
  else
    v_resultado := 'aprovado'::public.shopping_status_pagamento;
  end if;

  v_payload := jsonb_build_object(
    'source', 'mock_provider_auto',
    'scenario', v_config.cenario,
    'delay_ms', v_config.atraso_ms,
    'timeout_ms', v_config.timeout_ms,
    'expiration_ms', v_config.expiracao_ms,
    'processed_at', now()
  );

  select *
  into v_pagamento
  from public.shopping_pagamento_mock_simular(p_pagamento_id, v_resultado, v_payload);

  if v_config.cenario = 'timeout' then
    update public.shopping_pagamentos
    set erro_codigo = 'mock_timeout',
        erro_mensagem = 'Tempo limite do Mock Provider atingido sem confirmacao.',
        checkout_payload = checkout_payload || jsonb_build_object('timeout', true)
    where id = v_pagamento.id
    returning * into v_pagamento;

    perform public.shopping_pagamento_registrar_evento(
      v_pagamento.id,
      v_pagamento.pedido_id,
      'payment.mock.timeout',
      v_pagamento.status,
      jsonb_build_object('scenario', v_config.cenario, 'timeout_ms', v_config.timeout_ms)
    );

    insert into public.shopping_pagamento_logs (
      pagamento_id,
      pedido_id,
      nivel,
      mensagem,
      contexto
    )
    values (
      v_pagamento.id,
      v_pagamento.pedido_id,
      'warning',
      'Mock Provider atingiu timeout e manteve o pagamento pendente.',
      jsonb_build_object('scenario', v_config.cenario, 'timeout_ms', v_config.timeout_ms)
    );
  end if;

  return v_pagamento;
end;
$$;

drop function if exists public.shopping_pagamento_criar_rpc(uuid, text);

create or replace function public.shopping_pagamento_criar_rpc(
  p_pedido_id uuid,
  p_metodo text default 'pix'
)
returns public.shopping_pagamentos
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.shopping_pagamento_mock_criar_rpc(p_pedido_id, p_metodo);
end;
$$;

drop function if exists public.shopping_pagamento_processar_rpc(uuid);

create or replace function public.shopping_pagamento_processar_rpc(
  p_pagamento_id uuid
)
returns public.shopping_pagamentos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := public.shopping_carrinho_assert_user();
  v_pagamento public.shopping_pagamentos;
begin
  select *
  into v_pagamento
  from public.shopping_pagamentos
  where id = p_pagamento_id
    and (
      user_id = v_user_id
      or public.shopping_is_admin(v_user_id)
    );

  if v_pagamento.id is null then
    raise exception 'Pagamento nao encontrado para processamento.';
  end if;

  if v_pagamento.provedor = 'mock'::public.shopping_provedor_pagamento then
    return public.shopping_pagamento_mock_processar_rpc(p_pagamento_id);
  end if;

  raise exception 'Provider de pagamento ainda nao possui processador ativo.';
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
      pg.erro_mensagem as pagamento_erro_mensagem
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
      pg.erro_mensagem as pagamento_erro_mensagem
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

revoke all on public.shopping_pagamento_mock_config from anon, authenticated;
grant select on public.shopping_pagamento_mock_config to authenticated;

revoke all on function public.shopping_pagamento_mock_configurar(text, integer, integer, integer) from public, anon, authenticated;
revoke all on function public.shopping_pagamento_mock_processar_rpc(uuid) from public, anon, authenticated;
revoke all on function public.shopping_pagamento_criar_rpc(uuid, text) from public, anon, authenticated;
revoke all on function public.shopping_pagamento_processar_rpc(uuid) from public, anon, authenticated;
revoke all on function public.shopping_pedidos_cliente_listar() from public, anon, authenticated;
revoke all on function public.shopping_admin_listar_pedidos() from public, anon, authenticated;
revoke all on function public.shopping_admin_listar_pagamentos() from public, anon, authenticated;

grant execute on function public.shopping_pagamento_mock_configurar(text, integer, integer, integer) to authenticated;
grant execute on function public.shopping_pagamento_mock_processar_rpc(uuid) to authenticated;
grant execute on function public.shopping_pagamento_criar_rpc(uuid, text) to authenticated;
grant execute on function public.shopping_pagamento_processar_rpc(uuid) to authenticated;
grant execute on function public.shopping_pedidos_cliente_listar() to authenticated;
grant execute on function public.shopping_admin_listar_pedidos() to authenticated;
grant execute on function public.shopping_admin_listar_pagamentos() to authenticated;

comment on table public.shopping_pagamento_mock_config is
  'Configuracao operacional do Mock Provider de pagamentos do IAGO Shopping.';

comment on function public.shopping_pagamento_mock_configurar(text, integer, integer, integer) is
  'Configura o cenario do Mock Provider: sempre_aprovar, sempre_recusar, aleatorio, timeout ou expirar.';

comment on function public.shopping_pagamento_mock_processar_rpc(uuid) is
  'Processa automaticamente uma tentativa de pagamento mock como retorno de provider/webhook.';

comment on function public.shopping_pagamento_criar_rpc(uuid, text) is
  'Entrada generica do frontend para criar pagamento pelo provider configurado.';

comment on function public.shopping_pagamento_processar_rpc(uuid) is
  'Entrada generica do frontend para processar pagamento pelo provider configurado.';

notify pgrst, 'reload schema';
