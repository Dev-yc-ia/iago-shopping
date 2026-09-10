-- IAGO Shopping - WEB-10 ajuste de destravamento do parceiro.
--
-- O status do pedido continua usando o enum legado shopping_status_pedido
-- ('pendente_pagamento' ou 'cancelado'). A verdade financeira do fluxo e
-- shopping_pedidos.pagamento_status. Quando pagamento_status = 'aprovado',
-- a listagem do parceiro deve criar/recuperar a entrega pendente antes de
-- renderizar os botoes de envio/entrega pessoal.

create or replace function public.shopping_parceiro_reconciliar_pedidos_pagos_legados()
returns table (
  pedido_id uuid,
  numero bigint,
  numero_cliente bigint,
  item_id uuid,
  produto_id uuid,
  sku text,
  entrega_id uuid,
  snapshot_preenchido boolean,
  entrega_criada boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_perfil public.shopping_perfis := public.shopping_parceiro_ativo_assert(auth.uid());
  v_item record;
  v_entrega_id uuid;
  v_snapshot_preenchido boolean;
  v_entrega_criada boolean;
  v_snapshot_rows integer;
  v_item_antes jsonb;
begin
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
     and spe.parceiro_user_id = v_perfil.user_id
    where sp.status <> 'cancelado'::public.shopping_status_pedido
      and sp.pagamento_status = 'aprovado'::public.shopping_status_pagamento
      and spr.parceiro_user_id = v_perfil.user_id
      and spr.valor_repasse_parceiro is not null
      and spr.valor_repasse_parceiro >= 0
      and spr.valor_repasse_parceiro <= spi.preco_unitario
      and (
        spi.parceiro_user_id_snapshot is null
        or spi.parceiro_user_id_snapshot = v_perfil.user_id
      )
      and (
        spi.parceiro_user_id_snapshot is null
        or spi.valor_repasse_unitario_snapshot is null
        or spi.valor_repasse_total_snapshot is null
        or spe.id is null
        or sp.fulfillment_status = 'pendente_pagamento'
      )
    order by sp.criado_em, spi.criado_em, spi.id
    for update of sp, spi
  loop
    v_entrega_id := null;
    v_snapshot_preenchido := false;
    v_entrega_criada := false;
    v_snapshot_rows := 0;
    v_item_antes := null;

    if v_item.parceiro_user_id_snapshot is null
      or v_item.valor_repasse_unitario_snapshot is null
      or v_item.valor_repasse_total_snapshot is null then
      select to_jsonb(spi.*)
      into v_item_antes
      from public.shopping_pedido_itens spi
      where spi.id = v_item.item_id;

      update public.shopping_pedido_itens
      set parceiro_user_id_snapshot = coalesce(parceiro_user_id_snapshot, v_perfil.user_id),
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
      v_perfil.user_id,
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
        and spe.parceiro_user_id = v_perfil.user_id;
    end if;

    update public.shopping_pedidos
    set fulfillment_status = 'em_andamento'
    where id = v_item.pedido_id
      and fulfillment_status = 'pendente_pagamento'
      and pagamento_status = 'aprovado'::public.shopping_status_pagamento
      and status <> 'cancelado'::public.shopping_status_pedido;

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
        v_perfil.user_id,
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
          'parceiro_user_id', v_perfil.user_id,
          'repasse_snapshot', coalesce(v_item.valor_repasse_unitario_snapshot, v_item.produto_repasse),
          'pagamento_aprovado_em', v_item.pagamento_aprovado_em,
          'entrega_id', v_entrega_id,
          'timestamp_reconciliacao', now(),
          'origem', 'autocorrecao listagem parceiro WEB-10',
          'snapshot_preenchido', v_snapshot_preenchido,
          'entrega_criada', v_entrega_criada
        ),
        'Autocorrecao WEB-10 na listagem do parceiro, sem reprocessar pagamento ou estoque.'
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
      v_entrega_id,
      v_snapshot_preenchido,
      v_entrega_criada;
  end loop;
end;
$$;

create or replace function public.shopping_parceiro_listar_pedidos()
returns table (
  entrega_id uuid,
  pedido_id uuid,
  numero bigint,
  numero_cliente bigint,
  cliente_nome text,
  cliente_email text,
  endereco_entrega_snapshot jsonb,
  pagamento_status public.shopping_status_pagamento,
  entrega_status public.shopping_status_entrega,
  metodo_cumprimento public.shopping_metodo_cumprimento,
  repasse_status public.shopping_status_repasse,
  previsao_inicio date,
  previsao_fim date,
  parceiro_confirmado_em timestamptz,
  cliente_confirmado_em timestamptz,
  valor_repasse_total numeric,
  itens jsonb,
  criado_em timestamptz,
  atualizado_em timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_perfil public.shopping_perfis := public.shopping_parceiro_ativo_assert(auth.uid());
begin
  perform public.shopping_parceiro_reconciliar_pedidos_pagos_legados();

  return query
  select
    spe.id,
    sp.id,
    sp.numero,
    public.shopping_pedido_numero_cliente(sp.id),
    sp.cliente_nome,
    sp.cliente_email,
    sp.endereco_entrega_snapshot,
    sp.pagamento_status,
    spe.status,
    spe.metodo_cumprimento,
    spe.repasse_status,
    spe.previsao_inicio,
    spe.previsao_fim,
    spe.parceiro_confirmado_em,
    spe.cliente_confirmado_em,
    coalesce(sr.valor_repasse_total, 0)::numeric(12, 2),
    coalesce(si.itens, '[]'::jsonb),
    spe.criado_em,
    spe.atualizado_em
  from public.shopping_pedido_entregas spe
  join public.shopping_pedidos sp on sp.id = spe.pedido_id
  left join lateral (
    select coalesce(sum(spi.valor_repasse_total_snapshot), 0)::numeric(12, 2) as valor_repasse_total
    from public.shopping_pedido_itens spi
    where spi.pedido_id = spe.pedido_id
      and spi.parceiro_user_id_snapshot = v_perfil.user_id
  ) sr on true
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
        'subtotal', spi.subtotal,
        'valor_repasse_unitario_snapshot', spi.valor_repasse_unitario_snapshot,
        'valor_repasse_total_snapshot', spi.valor_repasse_total_snapshot
      )
      order by spi.criado_em, spi.id
    ) as itens
    from public.shopping_pedido_itens spi
    left join public.shopping_produto_variacoes spv on spv.id = spi.variacao_id
    where spi.pedido_id = spe.pedido_id
      and spi.parceiro_user_id_snapshot = v_perfil.user_id
  ) si on true
  where spe.parceiro_user_id = v_perfil.user_id
    and sp.status <> 'cancelado'::public.shopping_status_pedido
    and sp.pagamento_status = 'aprovado'::public.shopping_status_pagamento
  order by spe.atualizado_em desc, spe.criado_em desc;
end;
$$;

revoke all on function public.shopping_parceiro_reconciliar_pedidos_pagos_legados() from public, anon, authenticated;
revoke all on function public.shopping_parceiro_listar_pedidos() from public, anon, authenticated;

grant execute on function public.shopping_parceiro_reconciliar_pedidos_pagos_legados() to authenticated;
grant execute on function public.shopping_parceiro_listar_pedidos() to authenticated;

comment on function public.shopping_parceiro_reconciliar_pedidos_pagos_legados() is
  'Autocorrige entregas faltantes de pedidos pagos legados para o parceiro autenticado, sem reprocessar pagamento ou estoque.';

comment on function public.shopping_parceiro_listar_pedidos() is
  'Lista pedidos pagos do parceiro autenticado e autocorrige entregas legadas antes da leitura.';

notify pgrst, 'reload schema';
