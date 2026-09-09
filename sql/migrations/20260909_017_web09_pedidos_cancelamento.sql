-- IAGO Shopping - WEB-09
-- Numeracao visual por cliente, cancelamento de pedido e auditoria.
--
-- Escopo:
-- - preserva shopping_pedidos.numero como identificador tecnico global;
-- - retorna numero_cliente nas RPCs de cliente, admin e checkout;
-- - permite cancelamento de pedido nao aprovado pelo cliente dono;
-- - permite cancelamento administrativo somente por master;
-- - registra data, ator, origem, motivo e auditoria do cancelamento.

alter table public.shopping_pedidos
  add column if not exists numero_cliente bigint,
  add column if not exists cancelado_em timestamptz,
  add column if not exists cancelado_por_user_id uuid references auth.users(id) on delete set null,
  add column if not exists cancelado_por_tipo text,
  add column if not exists motivo_cancelamento text,
  add constraint shopping_pedidos_numero_cliente_positive
    check (numero_cliente is null or numero_cliente > 0),
  add constraint shopping_pedidos_cancelado_por_tipo_valid
    check (
      cancelado_por_tipo is null
      or cancelado_por_tipo in ('cliente', 'master', 'sistema')
    );

create index if not exists idx_shopping_pedidos_user_pagamento_numero_cliente
  on public.shopping_pedidos (user_id, pagamento_status, pagamento_confirmado_em, criado_em, id);

create index if not exists idx_shopping_pedidos_cancelado_data
  on public.shopping_pedidos (cancelado_em desc)
  where cancelado_em is not null;

drop function if exists public.shopping_pagamento_guard_pedido_cancelado();
create or replace function public.shopping_pagamento_guard_pedido_cancelado()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status in (
    'criado'::public.shopping_status_pagamento,
    'pendente'::public.shopping_status_pagamento,
    'aprovado'::public.shopping_status_pagamento
  ) and exists (
    select 1
    from public.shopping_pedidos sp
    where sp.id = new.pedido_id
      and (
        sp.status = 'cancelado'::public.shopping_status_pedido
        or sp.pagamento_status = 'cancelado'::public.shopping_status_pagamento
      )
  ) then
    raise exception 'Pedido cancelado nao aceita nova tentativa ou aprovacao de pagamento.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_shopping_pagamentos_guard_pedido_cancelado on public.shopping_pagamentos;
create trigger trg_shopping_pagamentos_guard_pedido_cancelado
before insert or update of status on public.shopping_pagamentos
for each row execute function public.shopping_pagamento_guard_pedido_cancelado();

drop function if exists public.shopping_pedido_numero_cliente(uuid);
create or replace function public.shopping_pedido_numero_cliente(
  p_pedido_id uuid
)
returns bigint
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pedido public.shopping_pedidos;
  v_referencia timestamptz;
  v_numero bigint;
begin
  select *
  into v_pedido
  from public.shopping_pedidos sp
  where sp.id = p_pedido_id;

  if v_pedido.id is null then
    return null;
  end if;

  if v_pedido.numero_cliente is not null then
    return v_pedido.numero_cliente;
  end if;

  if v_pedido.pagamento_status = 'aprovado'::public.shopping_status_pagamento then
    v_referencia := coalesce(v_pedido.pagamento_confirmado_em, v_pedido.atualizado_em, v_pedido.criado_em);

    select count(*)::bigint + 1
    into v_numero
    from public.shopping_pedidos sp
    where sp.user_id = v_pedido.user_id
      and sp.id <> v_pedido.id
      and sp.pagamento_status = 'aprovado'::public.shopping_status_pagamento
      and (
        coalesce(sp.pagamento_confirmado_em, sp.atualizado_em, sp.criado_em) < v_referencia
        or (
          coalesce(sp.pagamento_confirmado_em, sp.atualizado_em, sp.criado_em) = v_referencia
          and sp.criado_em < v_pedido.criado_em
        )
        or (
          coalesce(sp.pagamento_confirmado_em, sp.atualizado_em, sp.criado_em) = v_referencia
          and sp.criado_em = v_pedido.criado_em
          and sp.id::text < v_pedido.id::text
        )
      );

    return greatest(v_numero, 1);
  end if;

  v_referencia := case
    when v_pedido.status = 'cancelado'::public.shopping_status_pedido
      then coalesce(v_pedido.cancelado_em, v_pedido.atualizado_em, v_pedido.criado_em)
    else now()
  end;

  select count(*)::bigint + 1
  into v_numero
  from public.shopping_pedidos sp
  where sp.user_id = v_pedido.user_id
    and sp.pagamento_status = 'aprovado'::public.shopping_status_pagamento
    and coalesce(sp.pagamento_confirmado_em, sp.atualizado_em, sp.criado_em) < v_referencia;

  return greatest(v_numero, 1);
end;
$$;

update public.shopping_pedidos sp
set numero_cliente = public.shopping_pedido_numero_cliente(sp.id)
where sp.numero_cliente is null
  and sp.pagamento_status = 'aprovado'::public.shopping_status_pagamento;

drop function if exists public.shopping_pedido_cancelamento_auditar(
  public.shopping_pedidos,
  jsonb,
  uuid,
  text,
  text,
  uuid,
  public.shopping_status_pagamento,
  public.shopping_provedor_pagamento
);
create or replace function public.shopping_pedido_cancelamento_auditar(
  p_pedido public.shopping_pedidos,
  p_antes jsonb,
  p_ator_user_id uuid,
  p_ator_tipo text,
  p_motivo text,
  p_pagamento_id uuid default null,
  p_pagamento_status public.shopping_status_pagamento default null,
  p_pagamento_provedor public.shopping_provedor_pagamento default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
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
    p_ator_user_id,
    case
      when p_ator_tipo = 'master' then 'pedido.cancelado.master'
      else 'pedido.cancelado.cliente'
    end,
    'shopping_pedidos',
    p_pedido.id,
    p_antes,
    jsonb_build_object(
      'pedido_id', p_pedido.id,
      'numero_interno', p_pedido.numero,
      'numero_cliente', p_pedido.numero_cliente,
      'cliente_user_id', p_pedido.user_id,
      'ator_user_id', p_ator_user_id,
      'ator_tipo', p_ator_tipo,
      'motivo', p_motivo,
      'status_anterior', p_antes ->> 'status',
      'status_novo', p_pedido.status,
      'pagamento_status_anterior', p_antes ->> 'pagamento_status',
      'pagamento_status_novo', p_pedido.pagamento_status,
      'payment_id', p_pagamento_id,
      'payment_status', p_pagamento_status,
      'provider', p_pagamento_provedor,
      'cancelado_em', p_pedido.cancelado_em
    ),
    p_motivo
  );
end;
$$;

drop function if exists public.shopping_pedido_cancelar_base(uuid, text, text);
create or replace function public.shopping_pedido_cancelar_base(
  p_pedido_id uuid,
  p_motivo text,
  p_origem text
)
returns public.shopping_pedidos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_pedido public.shopping_pedidos;
  v_antes jsonb;
  v_pagamento public.shopping_pagamentos;
  v_numero_cliente bigint;
begin
  if v_actor is null then
    raise exception 'Operacao exige usuario autenticado.';
  end if;

  if p_pedido_id is null then
    raise exception 'Pedido obrigatorio para cancelamento.';
  end if;

  if p_origem not in ('cliente', 'master') then
    raise exception 'Origem de cancelamento invalida.';
  end if;

  select *
  into v_pedido
  from public.shopping_pedidos sp
  where sp.id = p_pedido_id
  for update;

  if v_pedido.id is null then
    raise exception 'Pedido nao encontrado para cancelamento.';
  end if;

  if p_origem = 'cliente' and v_pedido.user_id <> v_actor then
    raise exception 'Pedido nao pertence ao usuario autenticado.';
  end if;

  if p_origem = 'master' and not public.shopping_is_master(v_actor) then
    raise exception 'Somente master ativo pode cancelar pedido de cliente.';
  end if;

  if p_origem = 'master' and nullif(btrim(coalesce(p_motivo, '')), '') is null then
    raise exception 'Motivo obrigatorio para cancelamento master.';
  end if;

  if v_pedido.status = 'cancelado'::public.shopping_status_pedido then
    return v_pedido;
  end if;

  if v_pedido.pagamento_status = 'aprovado'::public.shopping_status_pagamento then
    raise exception 'Pedido aprovado nao pode ser cancelado sem fluxo de estorno.';
  end if;

  select *
  into v_pagamento
  from public.shopping_pagamentos pg
  where pg.pedido_id = v_pedido.id
  order by pg.criado_em desc
  limit 1
  for update;

  if v_pagamento.status in ('criado'::public.shopping_status_pagamento, 'pendente'::public.shopping_status_pagamento) then
    raise exception 'Cancele a tentativa de pagamento ativa antes de cancelar o pedido.';
  end if;

  v_numero_cliente := public.shopping_pedido_numero_cliente(v_pedido.id);
  v_antes := to_jsonb(v_pedido);

  update public.shopping_pedidos
  set status = 'cancelado'::public.shopping_status_pedido,
      pagamento_status = 'cancelado'::public.shopping_status_pagamento,
      numero_cliente = coalesce(numero_cliente, v_numero_cliente),
      cancelado_em = now(),
      cancelado_por_user_id = v_actor,
      cancelado_por_tipo = p_origem,
      motivo_cancelamento = coalesce(nullif(btrim(p_motivo), ''), 'Cancelado pelo cliente')
  where id = v_pedido.id
    and status <> 'cancelado'::public.shopping_status_pedido
    and pagamento_status <> 'aprovado'::public.shopping_status_pagamento
  returning * into v_pedido;

  if v_pedido.id is null then
    raise exception 'Pedido mudou durante o cancelamento. Atualize a tela e tente novamente.';
  end if;

  perform public.shopping_pagamento_reverter_estoque_pedido(v_pedido.id);

  perform public.shopping_pedido_cancelamento_auditar(
    v_pedido,
    v_antes,
    v_actor,
    p_origem,
    v_pedido.motivo_cancelamento,
    v_pagamento.id,
    v_pagamento.status,
    v_pagamento.provedor
  );

  return v_pedido;
end;
$$;

drop function if exists public.shopping_pedido_cliente_cancelar(uuid, text);
create or replace function public.shopping_pedido_cliente_cancelar(
  p_pedido_id uuid,
  p_motivo text default 'Cancelado pelo cliente'
)
returns table (
  id uuid,
  numero bigint,
  numero_cliente bigint,
  status public.shopping_status_pedido,
  pagamento_status public.shopping_status_pagamento,
  cancelado_em timestamptz,
  cancelado_por_tipo text,
  motivo_cancelamento text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pedido public.shopping_pedidos;
begin
  v_pedido := public.shopping_pedido_cancelar_base(p_pedido_id, p_motivo, 'cliente');

  return query
  select
    v_pedido.id,
    v_pedido.numero,
    public.shopping_pedido_numero_cliente(v_pedido.id),
    v_pedido.status,
    v_pedido.pagamento_status,
    v_pedido.cancelado_em,
    v_pedido.cancelado_por_tipo,
    v_pedido.motivo_cancelamento;
end;
$$;

drop function if exists public.shopping_admin_cancelar_pedido(uuid, text);
create or replace function public.shopping_admin_cancelar_pedido(
  p_pedido_id uuid,
  p_motivo text
)
returns table (
  id uuid,
  numero bigint,
  numero_cliente bigint,
  status public.shopping_status_pedido,
  pagamento_status public.shopping_status_pagamento,
  cancelado_em timestamptz,
  cancelado_por_tipo text,
  motivo_cancelamento text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pedido public.shopping_pedidos;
begin
  v_pedido := public.shopping_pedido_cancelar_base(p_pedido_id, p_motivo, 'master');

  return query
  select
    v_pedido.id,
    v_pedido.numero,
    public.shopping_pedido_numero_cliente(v_pedido.id),
    v_pedido.status,
    v_pedido.pagamento_status,
    v_pedido.cancelado_em,
    v_pedido.cancelado_por_tipo,
    v_pedido.motivo_cancelamento;
end;
$$;

drop function if exists public.shopping_pedidos_cliente_listar();
create or replace function public.shopping_pedidos_cliente_listar()
returns table (
  id uuid,
  numero bigint,
  numero_cliente bigint,
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
  cancelado_em timestamptz,
  cancelado_por_tipo text,
  motivo_cancelamento text,
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
    public.shopping_pedido_numero_cliente(sp.id) as numero_cliente,
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
    sp.cancelado_em,
    sp.cancelado_por_tipo,
    sp.motivo_cancelamento,
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
      and pg.status <> 'cancelado'::public.shopping_status_pagamento
      and (
        sp.pagamento_status = pg.status
        or pg.status in ('criado'::public.shopping_status_pagamento, 'pendente'::public.shopping_status_pagamento)
      )
    order by pg.criado_em desc
    limit 1
  ) spl on true
  left join lateral (
    select jsonb_agg(
      jsonb_build_object(
        'item_id', spi.id,
        'produto_id', spi.produto_id,
        'variacao_id', spi.variacao_id,
        'variacao_nome', spv.nome_variacao,
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
    left join public.shopping_produto_variacoes spv on spv.id = spi.variacao_id
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
  numero_cliente bigint,
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
  cancelado_em timestamptz,
  cancelado_por_tipo text,
  motivo_cancelamento text,
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
    public.shopping_pedido_numero_cliente(sp.id) as numero_cliente,
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
    sp.cancelado_em,
    sp.cancelado_por_tipo,
    sp.motivo_cancelamento,
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
      and pg.status <> 'cancelado'::public.shopping_status_pagamento
      and (
        sp.pagamento_status = pg.status
        or pg.status in ('criado'::public.shopping_status_pagamento, 'pendente'::public.shopping_status_pagamento)
      )
    order by pg.criado_em desc
    limit 1
  ) spl on true
  left join lateral (
    select jsonb_agg(
      jsonb_build_object(
        'item_id', spi.id,
        'produto_id', spi.produto_id,
        'variacao_id', spi.variacao_id,
        'variacao_nome', spv.nome_variacao,
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
    left join public.shopping_produto_variacoes spv on spv.id = spi.variacao_id
    where spi.pedido_id = sp.id
  ) si on true
  order by sp.criado_em desc, sp.numero desc;
end;
$$;

drop function if exists public.shopping_pagamento_checkout_context(uuid);
create or replace function public.shopping_pagamento_checkout_context(
  p_pedido_id uuid
)
returns table (
  pedido_id uuid,
  numero bigint,
  numero_cliente bigint,
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
    public.shopping_pedido_numero_cliente(sp.id) as numero_cliente,
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
        'variacao_id', spi.variacao_id,
        'variacao_nome', spv.nome_variacao,
        'quantidade', spi.quantidade,
        'preco_unitario', spi.preco_unitario,
        'subtotal', spi.subtotal
      )
      order by spi.criado_em, spi.id
    ) as itens
    from public.shopping_pedido_itens spi
    left join public.shopping_produto_variacoes spv on spv.id = spi.variacao_id
    where spi.pedido_id = sp.id
  ) si on true
  where sp.id = p_pedido_id
    and sp.user_id = auth.uid()
    and sp.status <> 'cancelado'::public.shopping_status_pedido
    and sp.pagamento_status <> 'cancelado'::public.shopping_status_pagamento;
$$;

revoke all on function public.shopping_pedido_numero_cliente(uuid) from public, anon, authenticated;
revoke all on function public.shopping_pagamento_guard_pedido_cancelado() from public, anon, authenticated;
revoke all on function public.shopping_pedido_cancelamento_auditar(
  public.shopping_pedidos,
  jsonb,
  uuid,
  text,
  text,
  uuid,
  public.shopping_status_pagamento,
  public.shopping_provedor_pagamento
) from public, anon, authenticated;
revoke all on function public.shopping_pedido_cancelar_base(uuid, text, text) from public, anon, authenticated;
revoke all on function public.shopping_pedido_cliente_cancelar(uuid, text) from public, anon, authenticated;
revoke all on function public.shopping_admin_cancelar_pedido(uuid, text) from public, anon, authenticated;
revoke all on function public.shopping_pedidos_cliente_listar() from public, anon, authenticated;
revoke all on function public.shopping_admin_listar_pedidos() from public, anon, authenticated;
revoke all on function public.shopping_pagamento_checkout_context(uuid) from public, anon, authenticated;

grant execute on function public.shopping_pedido_numero_cliente(uuid) to authenticated;
grant execute on function public.shopping_pedido_cliente_cancelar(uuid, text) to authenticated;
grant execute on function public.shopping_admin_cancelar_pedido(uuid, text) to authenticated;
grant execute on function public.shopping_pedidos_cliente_listar() to authenticated;
grant execute on function public.shopping_admin_listar_pedidos() to authenticated;
grant execute on function public.shopping_pagamento_checkout_context(uuid) to authenticated;

comment on column public.shopping_pedidos.numero_cliente is
  'Ordinal visual por cliente. Pedidos aprovados consolidam o numero; cancelados guardam o ordinal exibido no cancelamento.';

comment on function public.shopping_pedido_numero_cliente(uuid) is
  'Calcula o numero visual por cliente sem alterar o numero tecnico global do pedido.';

comment on function public.shopping_pagamento_guard_pedido_cancelado() is
  'Impede nova tentativa ou aprovacao tardia de pagamento para pedido ja cancelado.';

comment on function public.shopping_pedido_cliente_cancelar(uuid, text) is
  'Cancela pedido nao aprovado do proprio cliente apos cancelamento de tentativa ativa, usando auth.uid().';

comment on function public.shopping_admin_cancelar_pedido(uuid, text) is
  'Cancela pedido nao aprovado de qualquer cliente exclusivamente para master ativo, com motivo obrigatorio.';

notify pgrst, 'reload schema';
