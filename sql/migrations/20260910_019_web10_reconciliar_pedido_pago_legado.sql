-- IAGO Shopping - WEB-10 Adendo
-- Reconciliacao controlada de pedido aprovado antes do fluxo parceiro/entrega.
--
-- Uso principal em homologacao:
--   select * from public.shopping_admin_diagnosticar_pedido_pago_legado('TEN-HOCKS-010', null);
--   select * from public.shopping_admin_reconciliar_pedido_pago_legado('TEN-HOCKS-010', null);
--   select * from public.shopping_admin_reconciliar_pedido_pago_legado('TEN-HOCKS-010', null);
--
-- A rotina nao cria pagamento, nao chama provider, nao baixa estoque e nao sobrescreve snapshot existente.

drop function if exists public.shopping_admin_diagnosticar_pedido_pago_legado(text, uuid);
create or replace function public.shopping_admin_diagnosticar_pedido_pago_legado(
  p_sku text default null,
  p_pedido_id uuid default null
)
returns table (
  pedido_id uuid,
  numero bigint,
  numero_cliente bigint,
  item_id uuid,
  produto_id uuid,
  sku text,
  produto_parceiro_user_id uuid,
  produto_parceiro_nome text,
  produto_repasse numeric,
  pagamento_status public.shopping_status_pagamento,
  pagamento_aprovado_em timestamptz,
  parceiro_user_id_snapshot uuid,
  valor_repasse_unitario_snapshot numeric,
  valor_repasse_total_snapshot numeric,
  entrega_id uuid,
  entrega_status public.shopping_status_entrega,
  repasse_status public.shopping_status_repasse,
  elegivel_para_reconciliacao boolean,
  motivo text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.shopping_is_master(auth.uid()) then
    raise exception 'Somente master ativo pode diagnosticar pedido pago legado.';
  end if;

  if nullif(btrim(coalesce(p_sku, '')), '') is null and p_pedido_id is null then
    raise exception 'Informe SKU ou pedido_id para evitar diagnostico amplo.';
  end if;

  return query
  select
    sp.id,
    sp.numero,
    public.shopping_pedido_numero_cliente(sp.id),
    spi.id,
    spi.produto_id,
    spi.sku,
    spr.parceiro_user_id,
    coalesce(spar.nome_exibicao, spar.nome_completo, spar.email_normalizado),
    spr.valor_repasse_parceiro,
    sp.pagamento_status,
    coalesce(sp.pagamento_confirmado_em, pg.processado_em, pg.atualizado_em, pg.criado_em, sp.atualizado_em, sp.criado_em),
    spi.parceiro_user_id_snapshot,
    spi.valor_repasse_unitario_snapshot,
    spi.valor_repasse_total_snapshot,
    spe.id,
    spe.status,
    spe.repasse_status,
    (
      sp.status <> 'cancelado'::public.shopping_status_pedido
      and sp.pagamento_status = 'aprovado'::public.shopping_status_pagamento
      and spi.produto_id is not null
      and spr.parceiro_user_id is not null
      and spr.valor_repasse_parceiro is not null
      and spr.valor_repasse_parceiro >= 0
      and spr.valor_repasse_parceiro <= spi.preco_unitario
      and spar.user_id is not null
      and spar.papel = 'parceiro'::public.shopping_papel
      and spar.status_ativacao = 'ativo'::public.shopping_status_ativacao
      and (
        spi.parceiro_user_id_snapshot is null
        or spi.parceiro_user_id_snapshot = spr.parceiro_user_id
      )
      and (
        spi.parceiro_user_id_snapshot is null
        or spi.valor_repasse_unitario_snapshot is null
        or spi.valor_repasse_total_snapshot is null
        or spe.id is null
      )
    ) as elegivel_para_reconciliacao,
    case
      when sp.status = 'cancelado'::public.shopping_status_pedido then 'pedido cancelado'
      when sp.pagamento_status <> 'aprovado'::public.shopping_status_pagamento then 'pagamento nao aprovado'
      when spi.produto_id is null then 'item sem produto vinculado'
      when spr.parceiro_user_id is null then 'produto sem parceiro atual'
      when spr.valor_repasse_parceiro is null then 'produto sem repasse atual'
      when spr.valor_repasse_parceiro < 0 then 'repasse atual invalido'
      when spr.valor_repasse_parceiro > spi.preco_unitario then 'repasse atual maior que preco unitario vendido'
      when spar.user_id is null then 'parceiro atual nao encontrado'
      when spar.papel <> 'parceiro'::public.shopping_papel then 'perfil atual nao e parceiro'
      when spar.status_ativacao <> 'ativo'::public.shopping_status_ativacao then 'parceiro atual inativo'
      when spi.parceiro_user_id_snapshot is not null and spi.parceiro_user_id_snapshot <> spr.parceiro_user_id then 'snapshot existente aponta para outro parceiro'
      when spi.parceiro_user_id_snapshot is not null
        and spi.valor_repasse_unitario_snapshot is not null
        and spi.valor_repasse_total_snapshot is not null
        and spe.id is not null then 'ja reconciliado'
      else 'elegivel'
    end as motivo
  from public.shopping_pedido_itens spi
  join public.shopping_pedidos sp on sp.id = spi.pedido_id
  left join public.shopping_produtos spr on spr.id = spi.produto_id
  left join public.shopping_perfis spar on spar.user_id = spr.parceiro_user_id
  left join lateral (
    select pg_inner.*
    from public.shopping_pagamentos pg_inner
    where pg_inner.pedido_id = sp.id
      and pg_inner.status = 'aprovado'::public.shopping_status_pagamento
    order by pg_inner.processado_em desc nulls last, pg_inner.atualizado_em desc, pg_inner.criado_em desc
    limit 1
  ) pg on true
  left join public.shopping_pedido_entregas spe
    on spe.pedido_id = sp.id
   and spe.parceiro_user_id = coalesce(spi.parceiro_user_id_snapshot, spr.parceiro_user_id)
  where (nullif(btrim(coalesce(p_sku, '')), '') is null or spi.sku = upper(btrim(p_sku)) or spr.sku = upper(btrim(p_sku)))
    and (p_pedido_id is null or sp.id = p_pedido_id)
  order by sp.criado_em desc, spi.criado_em, spi.id;
end;
$$;

drop function if exists public.shopping_admin_reconciliar_pedido_pago_legado(text, uuid);
create or replace function public.shopping_admin_reconciliar_pedido_pago_legado(
  p_sku text default null,
  p_pedido_id uuid default null
)
returns table (
  pedido_id uuid,
  numero bigint,
  numero_cliente bigint,
  item_id uuid,
  produto_id uuid,
  sku text,
  parceiro_user_id uuid,
  valor_repasse_unitario_snapshot numeric,
  valor_repasse_total_snapshot numeric,
  pagamento_aprovado_em timestamptz,
  entrega_id uuid,
  snapshot_preenchido boolean,
  entrega_criada boolean,
  mensagem text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_item record;
  v_entrega_id uuid;
  v_snapshot_preenchido boolean;
  v_entrega_criada boolean;
  v_item_antes jsonb;
  v_item_depois jsonb;
  v_snapshot_rows integer;
begin
  if not public.shopping_is_master(v_actor) then
    raise exception 'Somente master ativo pode reconciliar pedido pago legado.';
  end if;

  if nullif(btrim(coalesce(p_sku, '')), '') is null and p_pedido_id is null then
    raise exception 'Informe SKU ou pedido_id para evitar backfill amplo.';
  end if;

  for v_item in
    select
      sp.id as pedido_id,
      sp.numero,
      public.shopping_pedido_numero_cliente(sp.id) as numero_cliente,
      spi.id as item_id,
      spi.produto_id,
      spi.sku,
      spi.quantidade,
      spi.preco_unitario,
      spi.parceiro_user_id_snapshot,
      spi.valor_repasse_unitario_snapshot,
      spi.valor_repasse_total_snapshot,
      spr.parceiro_user_id as produto_parceiro_user_id,
      spr.valor_repasse_parceiro as produto_repasse,
      coalesce(sp.pagamento_confirmado_em, pg.processado_em, pg.atualizado_em, pg.criado_em, sp.atualizado_em, sp.criado_em) as pagamento_aprovado_em
    from public.shopping_pedido_itens spi
    join public.shopping_pedidos sp on sp.id = spi.pedido_id
    join public.shopping_produtos spr on spr.id = spi.produto_id
    join public.shopping_perfis spar on spar.user_id = spr.parceiro_user_id
    left join lateral (
      select pg_inner.*
      from public.shopping_pagamentos pg_inner
      where pg_inner.pedido_id = sp.id
        and pg_inner.status = 'aprovado'::public.shopping_status_pagamento
      order by pg_inner.processado_em desc nulls last, pg_inner.atualizado_em desc, pg_inner.criado_em desc
      limit 1
    ) pg on true
    left join public.shopping_pedido_entregas spe
      on spe.pedido_id = sp.id
     and spe.parceiro_user_id = coalesce(spi.parceiro_user_id_snapshot, spr.parceiro_user_id)
    where (nullif(btrim(coalesce(p_sku, '')), '') is null or spi.sku = upper(btrim(p_sku)) or spr.sku = upper(btrim(p_sku)))
      and (p_pedido_id is null or sp.id = p_pedido_id)
      and sp.status <> 'cancelado'::public.shopping_status_pedido
      and sp.pagamento_status = 'aprovado'::public.shopping_status_pagamento
      and spr.parceiro_user_id is not null
      and spr.valor_repasse_parceiro is not null
      and spr.valor_repasse_parceiro >= 0
      and spr.valor_repasse_parceiro <= spi.preco_unitario
      and spar.papel = 'parceiro'::public.shopping_papel
      and spar.status_ativacao = 'ativo'::public.shopping_status_ativacao
      and (
        spi.parceiro_user_id_snapshot is null
        or spi.parceiro_user_id_snapshot = spr.parceiro_user_id
      )
      and (
        spi.parceiro_user_id_snapshot is null
        or spi.valor_repasse_unitario_snapshot is null
        or spi.valor_repasse_total_snapshot is null
        or spe.id is null
      )
    order by sp.criado_em, spi.criado_em, spi.id
    for update of sp, spi
  loop
    v_snapshot_preenchido := false;
    v_entrega_criada := false;
    v_entrega_id := null;
    v_item_antes := null;
    v_item_depois := null;
    v_snapshot_rows := 0;

    if v_item.parceiro_user_id_snapshot is null
      or v_item.valor_repasse_unitario_snapshot is null
      or v_item.valor_repasse_total_snapshot is null then
      select to_jsonb(spi.*)
      into v_item_antes
      from public.shopping_pedido_itens spi
      where spi.id = v_item.item_id;

      update public.shopping_pedido_itens
      set parceiro_user_id_snapshot = coalesce(parceiro_user_id_snapshot, v_item.produto_parceiro_user_id),
          valor_repasse_unitario_snapshot = coalesce(valor_repasse_unitario_snapshot, v_item.produto_repasse),
          valor_repasse_total_snapshot = coalesce(
            valor_repasse_total_snapshot,
            (coalesce(valor_repasse_unitario_snapshot, v_item.produto_repasse) * quantidade)::numeric(12, 2)
          )
      where id = v_item.item_id
        and (
          parceiro_user_id_snapshot is null
          or valor_repasse_unitario_snapshot is null
          or valor_repasse_total_snapshot is null
        );

      get diagnostics v_snapshot_rows = row_count;
      v_snapshot_preenchido := v_snapshot_rows > 0;

      if v_snapshot_preenchido then
        select to_jsonb(spi.*)
        into v_item_depois
        from public.shopping_pedido_itens spi
        where spi.id = v_item.item_id;
      end if;
    end if;

    insert into public.shopping_pedido_entregas (
      pedido_id,
      parceiro_user_id,
      status,
      pagamento_aprovado_em,
      previsao_inicio,
      previsao_fim,
      repasse_status
    )
    values (
      v_item.pedido_id,
      coalesce(v_item.parceiro_user_id_snapshot, v_item.produto_parceiro_user_id),
      'aguardando_parceiro'::public.shopping_status_entrega,
      v_item.pagamento_aprovado_em,
      (v_item.pagamento_aprovado_em + interval '12 days')::date,
      (v_item.pagamento_aprovado_em + interval '20 days')::date,
      'bloqueado'::public.shopping_status_repasse
    )
    on conflict on constraint shopping_pedido_entregas_pedido_parceiro_unique
    do nothing
    returning id into v_entrega_id;

    v_entrega_criada := v_entrega_id is not null;

    if v_entrega_id is null then
      select spe.id
      into v_entrega_id
      from public.shopping_pedido_entregas spe
      where spe.pedido_id = v_item.pedido_id
        and spe.parceiro_user_id = coalesce(v_item.parceiro_user_id_snapshot, v_item.produto_parceiro_user_id);
    end if;

    update public.shopping_pedidos
    set fulfillment_status = 'em_andamento'
    where id = v_item.pedido_id
      and fulfillment_status = 'pendente_pagamento';

    if v_snapshot_preenchido or v_entrega_criada then
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
        v_actor,
        'web10_legacy_order_reconciled',
        'shopping_pedido_itens',
        v_item.item_id,
        v_item_antes,
        jsonb_build_object(
          'pedido_id', v_item.pedido_id,
          'numero', v_item.numero,
          'numero_cliente', v_item.numero_cliente,
          'item_id', v_item.item_id,
          'produto_id', v_item.produto_id,
          'sku', v_item.sku,
          'parceiro_user_id', coalesce(v_item.parceiro_user_id_snapshot, v_item.produto_parceiro_user_id),
          'repasse_snapshot', coalesce(v_item.valor_repasse_unitario_snapshot, v_item.produto_repasse),
          'pagamento_aprovado_em', v_item.pagamento_aprovado_em,
          'entrega_id', v_entrega_id,
          'timestamp_reconciliacao', now(),
          'origem', 'backfill WEB-10',
          'snapshot_preenchido', v_snapshot_preenchido,
          'entrega_criada', v_entrega_criada
        ),
        'Backfill/reconciliacao WEB-10 de pedido pago legado sem reprocessar pagamento ou estoque.'
      );
    end if;

    return query
    select
      v_item.pedido_id,
      v_item.numero,
      v_item.numero_cliente,
      v_item.item_id,
      v_item.produto_id,
      v_item.sku,
      coalesce(v_item.parceiro_user_id_snapshot, v_item.produto_parceiro_user_id),
      coalesce(v_item.valor_repasse_unitario_snapshot, v_item.produto_repasse),
      coalesce(v_item.valor_repasse_total_snapshot, (v_item.produto_repasse * v_item.quantidade)::numeric(12, 2)),
      v_item.pagamento_aprovado_em,
      v_entrega_id,
      v_snapshot_preenchido,
      v_entrega_criada,
      case
        when v_snapshot_preenchido and v_entrega_criada then 'snapshot preenchido e fulfillment criado'
        when v_snapshot_preenchido then 'snapshot preenchido; fulfillment ja existia'
        when v_entrega_criada then 'fulfillment criado com snapshot existente'
        else 'ja reconciliado'
      end;
  end loop;
end;
$$;

revoke all on function public.shopping_admin_diagnosticar_pedido_pago_legado(text, uuid) from public, anon, authenticated;
revoke all on function public.shopping_admin_reconciliar_pedido_pago_legado(text, uuid) from public, anon, authenticated;

grant execute on function public.shopping_admin_diagnosticar_pedido_pago_legado(text, uuid) to authenticated;
grant execute on function public.shopping_admin_reconciliar_pedido_pago_legado(text, uuid) to authenticated;

comment on function public.shopping_admin_diagnosticar_pedido_pago_legado(text, uuid) is
  'Diagnostica pedido pago legado por SKU ou pedido_id antes da reconciliacao WEB-10, sem alterar dados.';

comment on function public.shopping_admin_reconciliar_pedido_pago_legado(text, uuid) is
  'Preenche snapshot comercial ausente e cria fulfillment faltante para pedido aprovado legado, sem reprocessar pagamento e sem movimentar estoque.';

notify pgrst, 'reload schema';
