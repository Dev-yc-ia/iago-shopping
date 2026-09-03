-- Fase 9B - Cancelamento profissional de tentativa de pagamento.
--
-- Escopo:
-- - permitir que o cliente cancele apenas a tentativa de pagamento atual;
-- - manter o pedido pendente para nova tentativa;
-- - registrar evento, log e auditoria;
-- - manter tentativas canceladas no historico tecnico sem prende-las no checkout.

drop function if exists public.shopping_pagamento_cancelar_tentativa_rpc(uuid, jsonb);
create or replace function public.shopping_pagamento_cancelar_tentativa_rpc(
  p_pagamento_id uuid,
  p_payload jsonb default '{}'::jsonb
)
returns public.shopping_pagamentos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := public.shopping_carrinho_assert_user();
  v_pagamento public.shopping_pagamentos;
  v_antes jsonb;
  v_payload jsonb;
begin
  select pg.*
  into v_pagamento
  from public.shopping_pagamentos pg
  join public.shopping_pedidos sp on sp.id = pg.pedido_id
  where pg.id = p_pagamento_id
    and (
      pg.user_id = v_user_id
      or sp.user_id = v_user_id
      or public.shopping_is_admin(v_user_id)
    )
  for update;

  if v_pagamento.id is null then
    raise exception 'Tentativa de pagamento nao encontrada para cancelamento.';
  end if;

  if v_pagamento.status = 'aprovado'::public.shopping_status_pagamento then
    raise exception 'Pagamento aprovado nao pode ser cancelado pelo checkout.';
  end if;

  if v_pagamento.status = 'cancelado'::public.shopping_status_pagamento then
    update public.shopping_pedidos
    set pagamento_status = 'pendente'::public.shopping_status_pagamento
    where id = v_pagamento.pedido_id
      and pagamento_status <> 'aprovado'::public.shopping_status_pagamento;

    return v_pagamento;
  end if;

  v_antes := to_jsonb(v_pagamento);
  v_payload := jsonb_build_object(
    'source', 'checkout',
    'cancelled_by', 'cliente',
    'cancelled_at', now()
  ) || coalesce(p_payload, '{}'::jsonb);

  update public.shopping_pagamentos
  set status = 'cancelado'::public.shopping_status_pagamento,
      erro_codigo = 'cliente_cancelou_tentativa',
      erro_mensagem = 'Tentativa de pagamento cancelada pelo cliente.',
      processado_em = coalesce(processado_em, now()),
      provider_payload = coalesce(provider_payload, '{}'::jsonb)
        || jsonb_build_object('cancelamento_cliente', v_payload),
      ultima_sincronizacao = now()
  where id = v_pagamento.id
  returning * into v_pagamento;

  update public.shopping_pedidos
  set pagamento_status = 'pendente'::public.shopping_status_pagamento
  where id = v_pagamento.pedido_id
    and pagamento_status <> 'aprovado'::public.shopping_status_pagamento;

  perform public.shopping_pagamento_registrar_evento(
    v_pagamento.id,
    v_pagamento.pedido_id,
    'payment.checkout.cancelled_by_customer',
    'cancelado'::public.shopping_status_pagamento,
    v_payload
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
    'pagamento.checkout.cancelar_tentativa',
    'shopping_pagamentos',
    v_pagamento.id,
    v_antes,
    to_jsonb(v_pagamento),
    'Cliente cancelou a tentativa de pagamento sem cancelar o pedido.'
  );

  return v_pagamento;
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

revoke all on function public.shopping_pagamento_cancelar_tentativa_rpc(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.shopping_pagamento_cancelar_tentativa_rpc(uuid, jsonb) to authenticated;
grant execute on function public.shopping_pagamento_cancelar_tentativa_rpc(uuid, jsonb) to service_role;

revoke all on function public.shopping_pedidos_cliente_listar() from public, anon, authenticated;
revoke all on function public.shopping_admin_listar_pedidos() from public, anon, authenticated;
grant execute on function public.shopping_pedidos_cliente_listar() to authenticated;
grant execute on function public.shopping_admin_listar_pedidos() to authenticated;

comment on function public.shopping_pagamento_cancelar_tentativa_rpc(uuid, jsonb) is
  'Cancela somente a tentativa de pagamento atual, mantendo o pedido pendente para nova tentativa.';

comment on function public.shopping_pedidos_cliente_listar() is
  'Lista pedidos do cliente e ignora tentativas canceladas como pagamento ativo do checkout.';

comment on function public.shopping_admin_listar_pedidos() is
  'Lista pedidos para admin e ignora tentativas canceladas como pagamento ativo, mantendo historico em shopping_pagamentos.';

notify pgrst, 'reload schema';
