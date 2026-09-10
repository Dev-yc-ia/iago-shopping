-- IAGO Shopping - WEB-10
-- Parceiros por produto, entrega por parceiro, recebimento pelo cliente e elegibilidade de repasse.
--
-- Escopo:
-- - pagamento aprovado inicia cumprimento operacional, mas nao conclui o pedido;
-- - produto guarda parceiro responsavel e valor de repasse para vendas futuras;
-- - pedido guarda snapshot comercial por item e snapshot do endereco de entrega;
-- - fulfillment por parceiro fica separado de pagamento e de repasse;
-- - parceiro confirma envio/entrega pessoal; cliente confirma recebimento;
-- - repasse fica elegivel somente apos confirmacao do cliente;
-- - nenhuma transferencia financeira e executada nesta fase.

alter table public.shopping_produtos
  add column if not exists parceiro_user_id uuid references public.shopping_perfis(user_id) on delete restrict,
  add column if not exists valor_repasse_parceiro numeric(12, 2),
  add constraint shopping_produtos_repasse_non_negative
    check (valor_repasse_parceiro is null or valor_repasse_parceiro >= 0),
  add constraint shopping_produtos_repasse_lte_preco
    check (valor_repasse_parceiro is null or valor_repasse_parceiro <= preco);

create index if not exists idx_shopping_produtos_parceiro_status
  on public.shopping_produtos (parceiro_user_id, status)
  where parceiro_user_id is not null;

alter table public.shopping_pedido_itens
  add column if not exists parceiro_user_id_snapshot uuid references public.shopping_perfis(user_id) on delete restrict,
  add column if not exists valor_repasse_unitario_snapshot numeric(12, 2),
  add column if not exists valor_repasse_total_snapshot numeric(12, 2),
  add constraint shopping_pedido_itens_repasse_unit_non_negative
    check (valor_repasse_unitario_snapshot is null or valor_repasse_unitario_snapshot >= 0),
  add constraint shopping_pedido_itens_repasse_total_non_negative
    check (valor_repasse_total_snapshot is null or valor_repasse_total_snapshot >= 0);

create index if not exists idx_shopping_pedido_itens_parceiro_snapshot
  on public.shopping_pedido_itens (parceiro_user_id_snapshot, pedido_id)
  where parceiro_user_id_snapshot is not null;

alter table public.shopping_pedidos
  add column if not exists endereco_entrega_snapshot jsonb,
  add column if not exists fulfillment_status text not null default 'pendente_pagamento',
  add constraint shopping_pedidos_endereco_snapshot_object
    check (endereco_entrega_snapshot is null or jsonb_typeof(endereco_entrega_snapshot) = 'object'),
  add constraint shopping_pedidos_fulfillment_status_valid
    check (fulfillment_status in ('pendente_pagamento', 'em_andamento', 'concluido', 'cancelado'));

do $$
begin
  create type public.shopping_status_entrega as enum (
    'aguardando_parceiro',
    'enviado',
    'entregue_pessoalmente',
    'recebido_cliente',
    'cancelado'
  );
exception
  when duplicate_object then null;
end
$$;

do $$
begin
  create type public.shopping_metodo_cumprimento as enum (
    'envio',
    'entrega_pessoal'
  );
exception
  when duplicate_object then null;
end
$$;

do $$
begin
  create type public.shopping_status_repasse as enum (
    'bloqueado',
    'elegivel',
    'pago'
  );
exception
  when duplicate_object then null;
end
$$;

drop function if exists public.shopping_is_master_or_funcionario(uuid);
create or replace function public.shopping_is_master_or_funcionario(
  p_user_id uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.shopping_perfis sp
    where sp.user_id = p_user_id
      and sp.status_ativacao = 'ativo'::public.shopping_status_ativacao
      and sp.papel in (
        'master'::public.shopping_papel,
        'funcionario'::public.shopping_papel
      )
  );
$$;

create table if not exists public.shopping_pedido_entregas (
  id uuid primary key default gen_random_uuid(),
  pedido_id uuid not null references public.shopping_pedidos(id) on delete cascade,
  parceiro_user_id uuid not null references public.shopping_perfis(user_id) on delete restrict,
  status public.shopping_status_entrega not null default 'aguardando_parceiro',
  metodo_cumprimento public.shopping_metodo_cumprimento,
  pagamento_aprovado_em timestamptz not null,
  previsao_inicio date not null,
  previsao_fim date not null,
  parceiro_confirmado_em timestamptz,
  parceiro_confirmado_por uuid references auth.users(id) on delete set null,
  cliente_confirmado_em timestamptz,
  cliente_confirmado_por uuid references auth.users(id) on delete set null,
  repasse_status public.shopping_status_repasse not null default 'bloqueado',
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint shopping_pedido_entregas_pedido_parceiro_unique unique (pedido_id, parceiro_user_id),
  constraint shopping_pedido_entregas_previsao_ordem check (previsao_fim >= previsao_inicio)
);

create index if not exists idx_shopping_pedido_entregas_parceiro_status
  on public.shopping_pedido_entregas (parceiro_user_id, status, criado_em desc);

create index if not exists idx_shopping_pedido_entregas_pedido_status
  on public.shopping_pedido_entregas (pedido_id, status);

drop trigger if exists trg_shopping_pedido_entregas_touch on public.shopping_pedido_entregas;
create trigger trg_shopping_pedido_entregas_touch
before update on public.shopping_pedido_entregas
for each row execute function public.shopping_touch_atualizado_em();

alter table public.shopping_pedido_entregas enable row level security;

drop policy if exists shopping_pedidos_select_own_or_admin on public.shopping_pedidos;
create policy shopping_pedidos_select_own_or_admin
on public.shopping_pedidos
for select
to authenticated
using (
  user_id = auth.uid()
  or public.shopping_is_master_or_funcionario(auth.uid())
  or exists (
    select 1
    from public.shopping_pedido_entregas spe
    where spe.pedido_id = shopping_pedidos.id
      and spe.parceiro_user_id = auth.uid()
      and shopping_pedidos.pagamento_status = 'aprovado'::public.shopping_status_pagamento
  )
);

drop policy if exists shopping_pedido_itens_select_own_or_admin on public.shopping_pedido_itens;
create policy shopping_pedido_itens_select_own_or_admin
on public.shopping_pedido_itens
for select
to authenticated
using (
  exists (
    select 1
    from public.shopping_pedidos sp
    where sp.id = shopping_pedido_itens.pedido_id
      and (
        sp.user_id = auth.uid()
        or public.shopping_is_master_or_funcionario(auth.uid())
        or (
          sp.pagamento_status = 'aprovado'::public.shopping_status_pagamento
          and shopping_pedido_itens.parceiro_user_id_snapshot = auth.uid()
          and exists (
            select 1
            from public.shopping_pedido_entregas spe
            where spe.pedido_id = sp.id
              and spe.parceiro_user_id = auth.uid()
          )
        )
      )
  )
);

drop policy if exists shopping_pagamentos_select_own_or_admin on public.shopping_pagamentos;
create policy shopping_pagamentos_select_own_or_admin
on public.shopping_pagamentos
for select
to authenticated
using (
  user_id = auth.uid()
  or public.shopping_is_master_or_funcionario(auth.uid())
);

drop policy if exists shopping_pagamento_eventos_select_own_or_admin on public.shopping_pagamento_eventos;
create policy shopping_pagamento_eventos_select_own_or_admin
on public.shopping_pagamento_eventos
for select
to authenticated
using (
  exists (
    select 1
    from public.shopping_pagamentos sp
    where sp.id = pagamento_id
      and (
        sp.user_id = auth.uid()
        or public.shopping_is_master_or_funcionario(auth.uid())
      )
  )
  or public.shopping_is_master_or_funcionario(auth.uid())
);

drop policy if exists shopping_pagamento_logs_select_admin on public.shopping_pagamento_logs;
create policy shopping_pagamento_logs_select_admin
on public.shopping_pagamento_logs
for select
to authenticated
using (public.shopping_is_master_or_funcionario(auth.uid()));

drop policy if exists shopping_email_fila_select_admin on public.shopping_email_fila;
create policy shopping_email_fila_select_admin
on public.shopping_email_fila
for select
to authenticated
using (public.shopping_is_master_or_funcionario(auth.uid()));

drop policy if exists shopping_pedido_entregas_select_scoped on public.shopping_pedido_entregas;
create policy shopping_pedido_entregas_select_scoped
on public.shopping_pedido_entregas
for select
to authenticated
using (
  parceiro_user_id = auth.uid()
  or public.shopping_is_master_or_funcionario(auth.uid())
  or exists (
    select 1
    from public.shopping_pedidos sp
    where sp.id = pedido_id
      and sp.user_id = auth.uid()
  )
);

revoke all on public.shopping_pedido_entregas from anon, authenticated;
grant select on public.shopping_pedido_entregas to authenticated;

revoke select on public.shopping_produtos from anon, authenticated;
grant select (
  id,
  sku,
  nome,
  marca,
  categoria,
  preco,
  destaque,
  descricao,
  atributos,
  status,
  criado_por,
  atualizado_por,
  criado_em,
  atualizado_em
) on public.shopping_produtos to anon, authenticated;

revoke select on public.shopping_pedido_itens from authenticated;
grant select (
  id,
  pedido_id,
  produto_id,
  variacao_id,
  sku,
  nome,
  marca,
  categoria,
  imagem_url,
  quantidade,
  preco_unitario,
  subtotal,
  criado_em
) on public.shopping_pedido_itens to authenticated;

drop policy if exists shopping_pagamento_provider_config_select_admin on public.shopping_pagamento_provider_config;
create policy shopping_pagamento_provider_config_select_admin
on public.shopping_pagamento_provider_config
for select
to authenticated
using (public.shopping_is_master_or_funcionario(auth.uid()));

drop policy if exists shopping_pagamento_mock_config_select_admin on public.shopping_pagamento_mock_config;
create policy shopping_pagamento_mock_config_select_admin
on public.shopping_pagamento_mock_config
for select
to authenticated
using (public.shopping_is_master_or_funcionario(auth.uid()));

drop function if exists public.shopping_admin_listar_parceiros_ativos();
create or replace function public.shopping_admin_listar_parceiros_ativos()
returns table (
  user_id uuid,
  nome_exibicao text,
  nome_completo text,
  email_normalizado text,
  telefone_normalizado text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.shopping_is_master(auth.uid()) then
    raise exception 'Somente master ativo pode listar parceiros para cadastro comercial.';
  end if;

  return query
  select
    sp.user_id,
    sp.nome_exibicao,
    sp.nome_completo,
    sp.email_normalizado,
    sp.telefone_normalizado
  from public.shopping_perfis sp
  where sp.papel = 'parceiro'::public.shopping_papel
    and sp.status_ativacao = 'ativo'::public.shopping_status_ativacao
  order by sp.nome_exibicao nulls last, sp.email_normalizado nulls last, sp.criado_em desc;
end;
$$;

drop function if exists public.shopping_parceiro_ativo_assert(uuid);
create or replace function public.shopping_parceiro_ativo_assert(
  p_user_id uuid
)
returns public.shopping_perfis
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_perfil public.shopping_perfis;
begin
  select *
  into v_perfil
  from public.shopping_perfis sp
  where sp.user_id = p_user_id
    and sp.papel = 'parceiro'::public.shopping_papel
    and sp.status_ativacao = 'ativo'::public.shopping_status_ativacao;

  if v_perfil.id is null then
    raise exception 'Parceiro responsavel precisa estar ativo.';
  end if;

  return v_perfil;
end;
$$;

drop function if exists public.shopping_entregas_json(uuid, boolean);
create or replace function public.shopping_entregas_json(
  p_pedido_id uuid,
  p_admin boolean default false
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'entrega_id', spe.id,
        'pedido_id', spe.pedido_id,
        'parceiro_user_id', spe.parceiro_user_id,
        'parceiro_nome', coalesce(spf.nome_exibicao, spf.nome_completo, spf.email_normalizado),
        'parceiro_email', case when p_admin then spf.email_normalizado else null end,
        'status', spe.status,
        'metodo_cumprimento', spe.metodo_cumprimento,
        'previsao_inicio', spe.previsao_inicio,
        'previsao_fim', spe.previsao_fim,
        'parceiro_confirmado_em', spe.parceiro_confirmado_em,
        'cliente_confirmado_em', spe.cliente_confirmado_em,
        'repasse_status', case when p_admin then spe.repasse_status else null end,
        'valor_repasse_total', case when p_admin then coalesce(sr.valor_repasse_total, 0) else null end,
        'itens', coalesce(si.itens, '[]'::jsonb)
      )
      order by spe.criado_em, spe.id
    ),
    '[]'::jsonb
  )
  from public.shopping_pedido_entregas spe
  left join public.shopping_perfis spf on spf.user_id = spe.parceiro_user_id
  left join lateral (
    select coalesce(sum(spi.valor_repasse_total_snapshot), 0)::numeric(12, 2) as valor_repasse_total
    from public.shopping_pedido_itens spi
    where spi.pedido_id = spe.pedido_id
      and spi.parceiro_user_id_snapshot = spe.parceiro_user_id
  ) sr on true
  left join lateral (
    select jsonb_agg(
      jsonb_build_object(
        'item_id', spi.id,
        'produto_id', spi.produto_id,
        'variacao_id', spi.variacao_id,
        'sku', spi.sku,
        'nome', spi.nome,
        'marca', spi.marca,
        'categoria', spi.categoria,
        'imagem_url', spi.imagem_url,
        'quantidade', spi.quantidade,
        'preco_unitario', spi.preco_unitario,
        'subtotal', spi.subtotal,
        'valor_repasse_unitario_snapshot', case when p_admin then spi.valor_repasse_unitario_snapshot else null end,
        'valor_repasse_total_snapshot', case when p_admin then spi.valor_repasse_total_snapshot else null end
      )
      order by spi.criado_em, spi.id
    ) as itens
    from public.shopping_pedido_itens spi
    where spi.pedido_id = spe.pedido_id
      and spi.parceiro_user_id_snapshot = spe.parceiro_user_id
  ) si on true
  where spe.pedido_id = p_pedido_id;
$$;

drop function if exists public.shopping_admin_salvar_produto_com_variacoes(
  uuid, text, text, text, numeric, text, text, jsonb, jsonb, public.shopping_status_produto, jsonb
);
drop function if exists public.shopping_admin_salvar_produto_com_variacoes(
  uuid, text, text, text, numeric, text, text, jsonb, jsonb, public.shopping_status_produto, jsonb, uuid, numeric
);
create or replace function public.shopping_admin_salvar_produto_com_variacoes(
  p_id uuid,
  p_nome text,
  p_marca text,
  p_categoria text,
  p_preco numeric,
  p_destaque text default null,
  p_descricao text default null,
  p_atributos jsonb default '[]'::jsonb,
  p_imagens jsonb default '[]'::jsonb,
  p_status public.shopping_status_produto default 'rascunho',
  p_variacoes jsonb default '[]'::jsonb,
  p_parceiro_user_id uuid default null,
  p_valor_repasse_parceiro numeric default null
)
returns public.shopping_produtos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_perfil public.shopping_perfis := public.shopping_admin_assert_produtos_permitido();
  v_sku text;
  v_antes jsonb;
  v_produto public.shopping_produtos;
  v_imagem jsonb;
  v_is_master boolean := public.shopping_is_master(auth.uid());
begin
  if p_nome is null or btrim(p_nome) = '' then
    raise exception 'Nome e obrigatorio.';
  end if;

  if p_marca is null or btrim(p_marca) = '' then
    raise exception 'Marca e obrigatoria.';
  end if;

  if p_categoria is null or btrim(p_categoria) = '' then
    raise exception 'Categoria e obrigatoria.';
  end if;

  if p_preco is null or p_preco < 0 then
    raise exception 'Preco deve ser maior ou igual a zero.';
  end if;

  if p_valor_repasse_parceiro is not null and p_valor_repasse_parceiro < 0 then
    raise exception 'Repasse deve ser maior ou igual a zero.';
  end if;

  if p_valor_repasse_parceiro is not null and p_valor_repasse_parceiro > p_preco then
    raise exception 'Repasse ao parceiro nao pode ser maior que o preco final.';
  end if;

  if p_status = 'publicado'::public.shopping_status_produto
    and (p_parceiro_user_id is null or p_valor_repasse_parceiro is null) then
    raise exception 'Produto publicado precisa de parceiro ativo e repasse configurado.';
  end if;

  if p_parceiro_user_id is not null then
    perform public.shopping_parceiro_ativo_assert(p_parceiro_user_id);
  end if;

  if p_atributos is null or jsonb_typeof(p_atributos) <> 'array' then
    raise exception 'Atributos devem ser uma lista JSON.';
  end if;

  if p_imagens is null or jsonb_typeof(p_imagens) <> 'array' then
    raise exception 'Imagens devem ser uma lista JSON.';
  end if;

  if p_id is not null then
    select to_jsonb(sp.*)
    into v_antes
    from public.shopping_produtos sp
    where sp.id = p_id
    for update;

    select *
    into v_produto
    from public.shopping_produtos sp
    where sp.id = p_id
    for update;

    if v_produto.id is null then
      raise exception 'Produto nao encontrado para edicao.';
    end if;

    if v_perfil.papel = 'parceiro'::public.shopping_papel
      and v_produto.criado_por is distinct from auth.uid() then
      raise exception 'Parceiro so pode editar produtos criados por ele.';
    end if;

    if not v_is_master and (
      v_produto.parceiro_user_id is distinct from p_parceiro_user_id
      or v_produto.valor_repasse_parceiro is distinct from p_valor_repasse_parceiro
    ) then
      raise exception 'Somente master ativo pode alterar parceiro responsavel e repasse.';
    end if;

    v_sku := v_produto.sku;

    update public.shopping_produtos
    set nome = btrim(p_nome),
        marca = btrim(p_marca),
        categoria = btrim(p_categoria),
        preco = p_preco,
        destaque = nullif(btrim(p_destaque), ''),
        descricao = nullif(btrim(p_descricao), ''),
        atributos = p_atributos,
        status = p_status,
        parceiro_user_id = p_parceiro_user_id,
        valor_repasse_parceiro = p_valor_repasse_parceiro,
        atualizado_por = auth.uid()
    where id = p_id
    returning * into v_produto;
  else
    if not v_is_master and (p_parceiro_user_id is not null or p_valor_repasse_parceiro is not null) then
      raise exception 'Somente master ativo pode definir parceiro responsavel e repasse.';
    end if;

    v_sku := public.shopping_gerar_sku_produto(p_categoria, p_marca);

    insert into public.shopping_produtos (
      sku,
      nome,
      marca,
      categoria,
      preco,
      destaque,
      descricao,
      atributos,
      status,
      parceiro_user_id,
      valor_repasse_parceiro,
      criado_por,
      atualizado_por
    )
    values (
      v_sku,
      btrim(p_nome),
      btrim(p_marca),
      btrim(p_categoria),
      p_preco,
      nullif(btrim(p_destaque), ''),
      nullif(btrim(p_descricao), ''),
      p_atributos,
      p_status,
      p_parceiro_user_id,
      p_valor_repasse_parceiro,
      auth.uid(),
      auth.uid()
    )
    returning * into v_produto;
  end if;

  delete from public.shopping_produto_imagens
  where produto_id = v_produto.id;

  for v_imagem in select * from jsonb_array_elements(p_imagens)
  loop
    if nullif(btrim(v_imagem ->> 'url'), '') is not null then
      insert into public.shopping_produto_imagens (
        produto_id,
        url,
        texto_alternativo,
        ordem,
        principal
      )
      values (
        v_produto.id,
        btrim(v_imagem ->> 'url'),
        nullif(btrim(v_imagem ->> 'texto_alternativo'), ''),
        coalesce(nullif(v_imagem ->> 'ordem', '')::integer, 0),
        coalesce((v_imagem ->> 'principal')::boolean, false)
      );
    end if;
  end loop;

  perform public.shopping_admin_sincronizar_variacoes_produto(
    v_produto.id,
    coalesce(p_variacoes, '[]'::jsonb),
    'Cadastro administrativo de produto pela WEB-10.'
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
    case when p_id is null then 'produto.criar' else 'produto.atualizar' end,
    'shopping_produtos',
    v_produto.id,
    v_antes,
    to_jsonb(v_produto),
    'Cadastro de produto com parceiro/repasse pela WEB-10.'
  );

  if v_antes is null or (v_antes ->> 'parceiro_user_id')::uuid is distinct from v_produto.parceiro_user_id then
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
      'product_partner_assigned',
      'shopping_produtos',
      v_produto.id,
      jsonb_build_object('parceiro_user_id', v_antes ->> 'parceiro_user_id'),
      jsonb_build_object('parceiro_user_id', v_produto.parceiro_user_id),
      'Parceiro responsavel definido pela WEB-10.'
    );
  end if;

  if v_antes is null or (v_antes ->> 'valor_repasse_parceiro')::numeric is distinct from v_produto.valor_repasse_parceiro then
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
      'product_partner_payout_changed',
      'shopping_produtos',
      v_produto.id,
      jsonb_build_object('valor_repasse_parceiro', v_antes ->> 'valor_repasse_parceiro'),
      jsonb_build_object('valor_repasse_parceiro', v_produto.valor_repasse_parceiro),
      'Valor de repasse ao parceiro definido pela WEB-10.'
    );
  end if;

  return v_produto;
end;
$$;

drop function if exists public.shopping_admin_listar_produtos_com_estoque();
create or replace function public.shopping_admin_listar_produtos_com_estoque()
returns table (
  id uuid,
  sku text,
  nome text,
  marca text,
  categoria text,
  preco numeric,
  destaque text,
  descricao text,
  atributos jsonb,
  imagens jsonb,
  status public.shopping_status_produto,
  quantidade_estoque integer,
  variacoes jsonb,
  parceiro_user_id uuid,
  parceiro_nome text,
  parceiro_email text,
  valor_repasse_parceiro numeric,
  comercial_configurado boolean,
  criado_por uuid,
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
    sp.sku,
    sp.nome,
    sp.marca,
    sp.categoria,
    sp.preco,
    sp.destaque,
    sp.descricao,
    sp.atributos,
    si.imagens,
    sp.status,
    se.quantidade_estoque,
    public.shopping_variacoes_json(sp.id, false) as variacoes,
    sp.parceiro_user_id,
    coalesce(spar.nome_exibicao, spar.nome_completo, spar.email_normalizado) as parceiro_nome,
    spar.email_normalizado as parceiro_email,
    sp.valor_repasse_parceiro,
    sp.parceiro_user_id is not null and sp.valor_repasse_parceiro is not null as comercial_configurado,
    sp.criado_por,
    sp.criado_em,
    sp.atualizado_em
  from public.shopping_produtos sp
  left join public.shopping_perfis spar on spar.user_id = sp.parceiro_user_id
  left join lateral (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'url', spi.url,
          'texto_alternativo', spi.texto_alternativo,
          'ordem', spi.ordem,
          'principal', spi.principal
        )
        order by spi.ordem, spi.id
      ),
      '[]'::jsonb
    ) as imagens
    from public.shopping_produto_imagens spi
    where spi.produto_id = sp.id
  ) si on true
  left join lateral (
    select coalesce(sum(spv.estoque_atual) filter (where spv.ativo), 0)::integer as quantidade_estoque
    from public.shopping_produto_variacoes spv
    where spv.produto_id = sp.id
  ) se on true
  where v_perfil.papel <> 'parceiro'::public.shopping_papel
     or sp.parceiro_user_id = auth.uid()
  order by sp.atualizado_em desc, sp.nome;
end;
$$;

drop function if exists public.shopping_pedido_finalizar_carrinho();
create or replace function public.shopping_pedido_finalizar_carrinho()
returns public.shopping_pedidos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := public.shopping_carrinho_assert_user();
  v_perfil public.shopping_perfis;
  v_endereco jsonb;
  v_carrinho public.shopping_carrinhos;
  v_pedido public.shopping_pedidos;
  v_item record;
  v_variacao public.shopping_produto_variacoes;
  v_total numeric(12, 2);
  v_total_itens integer;
begin
  select *
  into v_perfil
  from public.shopping_perfis sp
  where sp.user_id = v_user_id
  limit 1;

  select to_jsonb(se.*) - 'id' - 'user_id' - 'criado_em' - 'atualizado_em'
  into v_endereco
  from public.shopping_enderecos se
  where se.user_id = v_user_id
    and se.padrao
  order by se.atualizado_em desc, se.id
  limit 1;

  select *
  into v_carrinho
  from public.shopping_carrinhos sc
  where sc.user_id = v_user_id
    and sc.status = 'ativo'::public.shopping_status_carrinho
  for update;

  if v_carrinho.id is null then
    raise exception 'Carrinho ativo nao encontrado para finalizar pedido.';
  end if;

  select
    count(*)::integer,
    coalesce(sum(sci.preco_unitario * sci.quantidade), 0)::numeric(12, 2)
  into v_total_itens, v_total
  from public.shopping_carrinho_itens sci
  where sci.carrinho_id = v_carrinho.id;

  if v_total_itens = 0 then
    raise exception 'Carrinho vazio nao pode gerar pedido.';
  end if;

  if exists (
    select 1
    from public.shopping_carrinho_itens sci
    join public.shopping_produtos sp on sp.id = sci.produto_id
    left join public.shopping_perfis spar on spar.user_id = sp.parceiro_user_id
    where sci.carrinho_id = v_carrinho.id
      and (
        sp.status <> 'publicado'::public.shopping_status_produto
        or sp.parceiro_user_id is null
        or sp.valor_repasse_parceiro is null
        or sp.valor_repasse_parceiro < 0
        or sp.valor_repasse_parceiro > sp.preco
        or spar.user_id is null
        or spar.papel <> 'parceiro'::public.shopping_papel
        or spar.status_ativacao <> 'ativo'::public.shopping_status_ativacao
      )
  ) then
    raise exception 'Um item do carrinho ainda nao esta configurado para entrega pelo parceiro. Remova o item ou fale com a IAGO.';
  end if;

  insert into public.shopping_pedidos (
    user_id,
    perfil_id,
    carrinho_id,
    status,
    pagamento_status,
    fulfillment_status,
    cliente_nome,
    cliente_email,
    endereco_entrega_snapshot,
    subtotal,
    total
  )
  values (
    v_user_id,
    v_perfil.id,
    v_carrinho.id,
    'pendente_pagamento'::public.shopping_status_pedido,
    'pendente'::public.shopping_status_pagamento,
    'pendente_pagamento',
    v_perfil.nome_exibicao,
    v_perfil.email_normalizado,
    v_endereco,
    v_total,
    v_total
  )
  returning * into v_pedido;

  for v_item in
    select
      sci.produto_id,
      sci.variacao_id,
      sci.quantidade,
      sci.preco_unitario,
      sp.sku,
      sp.nome,
      sp.marca,
      sp.categoria,
      sp.status,
      sp.parceiro_user_id,
      sp.valor_repasse_parceiro,
      si.imagem_url
    from public.shopping_carrinho_itens sci
    join public.shopping_produtos sp on sp.id = sci.produto_id
    left join lateral (
      select spi.url as imagem_url
      from public.shopping_produto_imagens spi
      where spi.produto_id = sp.id
      order by spi.principal desc, spi.ordem, spi.id
      limit 1
    ) si on true
    where sci.carrinho_id = v_carrinho.id
    order by sci.criado_em, sci.id
  loop
    select *
    into v_variacao
    from public.shopping_produto_variacoes spv
    where spv.id = v_item.variacao_id
      and spv.produto_id = v_item.produto_id
      and spv.ativo
    for update;

    if v_variacao.id is null then
      raise exception 'Variacao do carrinho indisponivel para pedido.';
    end if;

    if v_variacao.estoque_atual < v_item.quantidade then
      raise exception 'Quantidade solicitada maior que o estoque da variacao.';
    end if;

    insert into public.shopping_pedido_itens (
      pedido_id,
      produto_id,
      variacao_id,
      sku,
      nome,
      marca,
      categoria,
      imagem_url,
      quantidade,
      preco_unitario,
      subtotal,
      parceiro_user_id_snapshot,
      valor_repasse_unitario_snapshot,
      valor_repasse_total_snapshot
    )
    values (
      v_pedido.id,
      v_item.produto_id,
      v_variacao.id,
      v_item.sku,
      v_item.nome,
      v_item.marca,
      v_item.categoria,
      v_item.imagem_url,
      v_item.quantidade,
      v_item.preco_unitario,
      (v_item.preco_unitario * v_item.quantidade)::numeric(12, 2),
      v_item.parceiro_user_id,
      v_item.valor_repasse_parceiro,
      (v_item.valor_repasse_parceiro * v_item.quantidade)::numeric(12, 2)
    );
  end loop;

  update public.shopping_carrinhos
  set status = 'convertido'::public.shopping_status_carrinho
  where id = v_carrinho.id;

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
    'pedido.finalizar',
    'shopping_pedidos',
    v_pedido.id,
    jsonb_build_object('carrinho_id', v_carrinho.id),
    to_jsonb(v_pedido),
    'Pedido criado pela WEB-10 com snapshot comercial de parceiro/repasse.'
  );

  return v_pedido;
end;
$$;

drop function if exists public.shopping_pagamento_criar_entregas_pedido(uuid, timestamptz);
create or replace function public.shopping_pagamento_criar_entregas_pedido(
  p_pedido_id uuid,
  p_aprovado_em timestamptz default now()
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pedido public.shopping_pedidos;
  v_criadas integer := 0;
  v_entrega public.shopping_pedido_entregas;
begin
  select *
  into v_pedido
  from public.shopping_pedidos sp
  where sp.id = p_pedido_id
  for update;

  if v_pedido.id is null then
    raise exception 'Pedido nao encontrado para criar entregas.';
  end if;

  if v_pedido.pagamento_status <> 'aprovado'::public.shopping_status_pagamento then
    return 0;
  end if;

  for v_entrega in
    insert into public.shopping_pedido_entregas (
      pedido_id,
      parceiro_user_id,
      status,
      pagamento_aprovado_em,
      previsao_inicio,
      previsao_fim,
      repasse_status
    )
    select distinct
      v_pedido.id,
      spi.parceiro_user_id_snapshot,
      'aguardando_parceiro'::public.shopping_status_entrega,
      coalesce(p_aprovado_em, now()),
      (coalesce(p_aprovado_em, now()) + interval '12 days')::date,
      (coalesce(p_aprovado_em, now()) + interval '20 days')::date,
      'bloqueado'::public.shopping_status_repasse
    from public.shopping_pedido_itens spi
    join public.shopping_perfis spar on spar.user_id = spi.parceiro_user_id_snapshot
    where spi.pedido_id = v_pedido.id
      and spi.parceiro_user_id_snapshot is not null
      and spar.papel = 'parceiro'::public.shopping_papel
      and spar.status_ativacao = 'ativo'::public.shopping_status_ativacao
    on conflict on constraint shopping_pedido_entregas_pedido_parceiro_unique
    do nothing
    returning *
  loop
    v_criadas := v_criadas + 1;

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
      v_pedido.user_id,
      'fulfillment_created',
      'shopping_pedido_entregas',
      v_entrega.id,
      null,
      to_jsonb(v_entrega),
      'Entrega por parceiro criada de forma idempotente pela WEB-10.'
    );
  end loop;

  update public.shopping_pedidos
  set fulfillment_status = case
        when exists (
          select 1 from public.shopping_pedido_entregas spe where spe.pedido_id = v_pedido.id
        ) then 'em_andamento'
        else fulfillment_status
      end
  where id = v_pedido.id
    and fulfillment_status = 'pendente_pagamento';

  return v_criadas;
end;
$$;

drop function if exists public.shopping_pagamento_mock_simular(uuid, public.shopping_status_pagamento, jsonb);
create or replace function public.shopping_pagamento_mock_simular(
  p_pagamento_id uuid,
  p_resultado public.shopping_status_pagamento,
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
  v_pagamento_antes jsonb;
  v_aprovado_em timestamptz;
begin
  if p_resultado not in (
    'aprovado'::public.shopping_status_pagamento,
    'recusado'::public.shopping_status_pagamento,
    'pendente'::public.shopping_status_pagamento,
    'expirado'::public.shopping_status_pagamento,
    'cancelado'::public.shopping_status_pagamento
  ) then
    raise exception 'Resultado mock invalido para pagamento.';
  end if;

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
    raise exception 'Pagamento nao encontrado para simulacao.';
  end if;

  if v_pagamento.provedor <> 'mock'::public.shopping_provedor_pagamento then
    raise exception 'Somente pagamentos mock podem ser simulados localmente.';
  end if;

  if v_pagamento.status = 'aprovado'::public.shopping_status_pagamento
    and p_resultado = 'aprovado'::public.shopping_status_pagamento then
    perform public.shopping_pagamento_criar_entregas_pedido(v_pagamento.pedido_id, coalesce(v_pagamento.processado_em, now()));
    return v_pagamento;
  end if;

  if v_pagamento.status = 'aprovado'::public.shopping_status_pagamento
    and p_resultado <> 'aprovado'::public.shopping_status_pagamento then
    raise exception 'Pagamento aprovado nao pode voltar para outro status.';
  end if;

  v_pagamento_antes := to_jsonb(v_pagamento);

  update public.shopping_pagamentos
  set status = p_resultado,
      mock_resultado = p_resultado,
      erro_codigo = case
        when p_resultado in ('recusado'::public.shopping_status_pagamento, 'expirado'::public.shopping_status_pagamento, 'cancelado'::public.shopping_status_pagamento)
          then 'mock_' || p_resultado::text
        else null
      end,
      erro_mensagem = case
        when p_resultado = 'recusado'::public.shopping_status_pagamento then 'Pagamento recusado na simulacao mock.'
        when p_resultado = 'expirado'::public.shopping_status_pagamento then 'Pagamento expirado na simulacao mock.'
        when p_resultado = 'cancelado'::public.shopping_status_pagamento then 'Pagamento cancelado na simulacao mock.'
        else null
      end,
      processado_em = case
        when p_resultado = 'pendente'::public.shopping_status_pagamento then processado_em
        else now()
      end,
      checkout_payload = checkout_payload || coalesce(p_payload, '{}'::jsonb)
  where id = v_pagamento.id
  returning * into v_pagamento;

  if p_resultado = 'aprovado'::public.shopping_status_pagamento then
    v_aprovado_em := coalesce(v_pagamento.processado_em, now());

    perform public.shopping_pagamento_baixar_estoque_pedido(v_pagamento.pedido_id);

    update public.shopping_pedidos
    set pagamento_status = 'aprovado'::public.shopping_status_pagamento,
        pagamento_confirmado_em = v_aprovado_em
    where id = v_pagamento.pedido_id;

    perform public.shopping_pagamento_criar_entregas_pedido(v_pagamento.pedido_id, v_aprovado_em);
  elsif p_resultado in (
    'recusado'::public.shopping_status_pagamento,
    'expirado'::public.shopping_status_pagamento,
    'cancelado'::public.shopping_status_pagamento
  ) then
    update public.shopping_pedidos
    set pagamento_status = p_resultado,
        fulfillment_status = case
          when p_resultado = 'cancelado'::public.shopping_status_pagamento then 'cancelado'
          else fulfillment_status
        end
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
    'payment.mock.' || p_resultado::text,
    p_resultado,
    coalesce(p_payload, '{}'::jsonb)
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
    'pagamento.mock.simular',
    'shopping_pagamentos',
    v_pagamento.id,
    v_pagamento_antes,
    to_jsonb(v_pagamento),
    'Resultado de pagamento mock processado pela WEB-10.'
  );

  select *
  into v_pagamento
  from public.shopping_pagamentos sp
  where sp.id = p_pagamento_id;

  return v_pagamento;
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
  v_aprovado_em timestamptz;
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
    perform public.shopping_pagamento_criar_entregas_pedido(v_pagamento.pedido_id, coalesce(v_pagamento.processado_em, now()));
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
    v_aprovado_em := coalesce(v_pagamento.processado_em, now());

    perform public.shopping_pagamento_baixar_estoque_pedido(v_pagamento.pedido_id);

    update public.shopping_pedidos
    set pagamento_status = 'aprovado'::public.shopping_status_pagamento,
        pagamento_confirmado_em = v_aprovado_em
    where id = v_pagamento.pedido_id;

    perform public.shopping_pagamento_criar_entregas_pedido(v_pagamento.pedido_id, v_aprovado_em);
  elsif p_resultado in (
    'recusado'::public.shopping_status_pagamento,
    'expirado'::public.shopping_status_pagamento,
    'cancelado'::public.shopping_status_pagamento
  ) then
    update public.shopping_pedidos
    set pagamento_status = p_resultado,
        fulfillment_status = case
          when p_resultado = 'cancelado'::public.shopping_status_pagamento then 'cancelado'
          else fulfillment_status
        end
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
    'Resultado de pagamento aplicado pelo Payment Engine da WEB-10.'
  );

  return v_pagamento;
end;
$$;

drop function if exists public.shopping_parceiro_listar_pedidos();
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
stable
security definer
set search_path = public
as $$
declare
  v_perfil public.shopping_perfis := public.shopping_parceiro_ativo_assert(auth.uid());
begin
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
    and sp.pagamento_status = 'aprovado'::public.shopping_status_pagamento
  order by spe.atualizado_em desc, spe.criado_em desc;
end;
$$;

drop function if exists public.shopping_parceiro_confirmar_entrega(uuid, text);
create or replace function public.shopping_parceiro_confirmar_entrega(
  p_entrega_id uuid,
  p_metodo text default 'envio'
)
returns public.shopping_pedido_entregas
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_perfil public.shopping_perfis := public.shopping_parceiro_ativo_assert(auth.uid());
  v_entrega public.shopping_pedido_entregas;
  v_pedido public.shopping_pedidos;
  v_antes jsonb;
  v_metodo public.shopping_metodo_cumprimento;
  v_status public.shopping_status_entrega;
begin
  if p_entrega_id is null then
    raise exception 'Entrega obrigatoria para confirmacao.';
  end if;

  begin
    v_metodo := coalesce(nullif(btrim(p_metodo), ''), 'envio')::public.shopping_metodo_cumprimento;
  exception
    when invalid_text_representation then
      raise exception 'Metodo de cumprimento invalido.';
  end;

  v_status := case
    when v_metodo = 'entrega_pessoal'::public.shopping_metodo_cumprimento
      then 'entregue_pessoalmente'::public.shopping_status_entrega
    else 'enviado'::public.shopping_status_entrega
  end;

  select *
  into v_entrega
  from public.shopping_pedido_entregas spe
  where spe.id = p_entrega_id
  for update;

  if v_entrega.id is null then
    raise exception 'Entrega nao encontrada.';
  end if;

  if v_entrega.parceiro_user_id <> v_perfil.user_id then
    raise exception 'Entrega nao pertence ao parceiro autenticado.';
  end if;

  select *
  into v_pedido
  from public.shopping_pedidos sp
  where sp.id = v_entrega.pedido_id
  for update;

  if v_pedido.pagamento_status <> 'aprovado'::public.shopping_status_pagamento then
    raise exception 'Parceiro so pode confirmar entrega de pedido com pagamento aprovado.';
  end if;

  if v_entrega.status = v_status and v_entrega.parceiro_confirmado_em is not null then
    return v_entrega;
  end if;

  if v_entrega.status <> 'aguardando_parceiro'::public.shopping_status_entrega then
    raise exception 'Entrega nao esta aguardando confirmacao do parceiro.';
  end if;

  v_antes := to_jsonb(v_entrega);

  update public.shopping_pedido_entregas
  set status = v_status,
      metodo_cumprimento = v_metodo,
      parceiro_confirmado_em = now(),
      parceiro_confirmado_por = v_actor
  where id = v_entrega.id
  returning * into v_entrega;

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
    case
      when v_metodo = 'entrega_pessoal'::public.shopping_metodo_cumprimento
        then 'partner_marked_personal_delivery'
      else 'partner_marked_shipped'
    end,
    'shopping_pedido_entregas',
    v_entrega.id,
    v_antes,
    to_jsonb(v_entrega),
    'Parceiro confirmou cumprimento pela WEB-10.'
  );

  return v_entrega;
end;
$$;

drop function if exists public.shopping_cliente_confirmar_recebimento(uuid);
create or replace function public.shopping_cliente_confirmar_recebimento(
  p_entrega_id uuid
)
returns public.shopping_pedido_entregas
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_entrega public.shopping_pedido_entregas;
  v_pedido public.shopping_pedidos;
  v_antes jsonb;
  v_todas_recebidas boolean;
begin
  if v_actor is null then
    raise exception 'Operacao exige usuario autenticado.';
  end if;

  if p_entrega_id is null then
    raise exception 'Entrega obrigatoria para confirmar recebimento.';
  end if;

  select *
  into v_entrega
  from public.shopping_pedido_entregas spe
  where spe.id = p_entrega_id
  for update;

  if v_entrega.id is null then
    raise exception 'Entrega nao encontrada.';
  end if;

  select *
  into v_pedido
  from public.shopping_pedidos sp
  where sp.id = v_entrega.pedido_id
  for update;

  if v_pedido.user_id <> v_actor then
    raise exception 'Entrega nao pertence ao cliente autenticado.';
  end if;

  if v_pedido.pagamento_status <> 'aprovado'::public.shopping_status_pagamento then
    raise exception 'Recebimento so pode ser confirmado apos pagamento aprovado.';
  end if;

  if v_entrega.status = 'recebido_cliente'::public.shopping_status_entrega then
    return v_entrega;
  end if;

  if v_entrega.status not in (
    'enviado'::public.shopping_status_entrega,
    'entregue_pessoalmente'::public.shopping_status_entrega
  ) then
    raise exception 'Aguarde o parceiro confirmar envio ou entrega pessoal.';
  end if;

  v_antes := to_jsonb(v_entrega);

  update public.shopping_pedido_entregas
  set status = 'recebido_cliente'::public.shopping_status_entrega,
      cliente_confirmado_em = now(),
      cliente_confirmado_por = v_actor,
      repasse_status = 'elegivel'::public.shopping_status_repasse
  where id = v_entrega.id
  returning * into v_entrega;

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
    'customer_confirmed_receipt',
    'shopping_pedido_entregas',
    v_entrega.id,
    v_antes,
    to_jsonb(v_entrega),
    'Cliente confirmou recebimento pela WEB-10.'
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
    v_actor,
    'payout_became_eligible',
    'shopping_pedido_entregas',
    v_entrega.id,
    jsonb_build_object('repasse_status', v_antes ->> 'repasse_status'),
    jsonb_build_object('repasse_status', v_entrega.repasse_status),
    'Repasse tornou-se elegivel apos confirmacao do cliente.'
  );

  select not exists (
    select 1
    from public.shopping_pedido_entregas spe
    where spe.pedido_id = v_pedido.id
      and spe.status <> 'recebido_cliente'::public.shopping_status_entrega
  )
  into v_todas_recebidas;

  if v_todas_recebidas then
    update public.shopping_pedidos
    set fulfillment_status = 'concluido'
    where id = v_pedido.id;

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
      'order_fulfillment_completed',
      'shopping_pedidos',
      v_pedido.id,
      jsonb_build_object('fulfillment_status', v_pedido.fulfillment_status),
      jsonb_build_object('fulfillment_status', 'concluido'),
      'Todas as entregas do pedido foram recebidas pelo cliente.'
    );
  else
    update public.shopping_pedidos
    set fulfillment_status = 'em_andamento'
    where id = v_pedido.id
      and fulfillment_status <> 'concluido';
  end if;

  return v_entrega;
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
  fulfillment_status text,
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
  entregas jsonb,
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
    sp.fulfillment_status,
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
    public.shopping_entregas_json(sp.id, false) as entregas,
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
        'subtotal', spi.subtotal,
        'parceiro_user_id_snapshot', spi.parceiro_user_id_snapshot
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
  fulfillment_status text,
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
  endereco_entrega_snapshot jsonb,
  total numeric,
  moeda text,
  itens jsonb,
  entregas jsonb,
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
  if v_perfil.papel = 'parceiro'::public.shopping_papel then
    raise exception 'Parceiro deve consultar pedidos pela listagem escopada.';
  end if;

  return query
  select
    sp.id,
    sp.numero,
    public.shopping_pedido_numero_cliente(sp.id) as numero_cliente,
    sp.status,
    sp.pagamento_status,
    sp.fulfillment_status,
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
    sp.endereco_entrega_snapshot,
    sp.total,
    sp.moeda,
    coalesce(si.itens, '[]'::jsonb) as itens,
    public.shopping_entregas_json(sp.id, true) as entregas,
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
        'subtotal', spi.subtotal,
        'parceiro_user_id_snapshot', spi.parceiro_user_id_snapshot,
        'valor_repasse_unitario_snapshot', spi.valor_repasse_unitario_snapshot,
        'valor_repasse_total_snapshot', spi.valor_repasse_total_snapshot
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

revoke all on function public.shopping_admin_listar_parceiros_ativos() from public, anon, authenticated;
revoke all on function public.shopping_is_master_or_funcionario(uuid) from public, anon, authenticated;
revoke all on function public.shopping_parceiro_ativo_assert(uuid) from public, anon, authenticated;
revoke all on function public.shopping_entregas_json(uuid, boolean) from public, anon, authenticated;
revoke all on function public.shopping_admin_salvar_produto_com_variacoes(uuid, text, text, text, numeric, text, text, jsonb, jsonb, public.shopping_status_produto, jsonb, uuid, numeric) from public, anon, authenticated;
revoke all on function public.shopping_admin_listar_produtos_com_estoque() from public, anon, authenticated;
revoke all on function public.shopping_pedido_finalizar_carrinho() from public, anon, authenticated;
revoke all on function public.shopping_pagamento_criar_entregas_pedido(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.shopping_pagamento_mock_simular(uuid, public.shopping_status_pagamento, jsonb) from public, anon, authenticated;
revoke all on function public.shopping_pagamento_aplicar_resultado_provider(uuid, public.shopping_status_pagamento, text, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.shopping_parceiro_listar_pedidos() from public, anon, authenticated;
revoke all on function public.shopping_parceiro_confirmar_entrega(uuid, text) from public, anon, authenticated;
revoke all on function public.shopping_cliente_confirmar_recebimento(uuid) from public, anon, authenticated;
revoke all on function public.shopping_pedidos_cliente_listar() from public, anon, authenticated;
revoke all on function public.shopping_admin_listar_pedidos() from public, anon, authenticated;

grant execute on function public.shopping_admin_listar_parceiros_ativos() to authenticated;
grant execute on function public.shopping_is_master_or_funcionario(uuid) to authenticated;
grant execute on function public.shopping_admin_salvar_produto_com_variacoes(uuid, text, text, text, numeric, text, text, jsonb, jsonb, public.shopping_status_produto, jsonb, uuid, numeric) to authenticated;
grant execute on function public.shopping_admin_listar_produtos_com_estoque() to authenticated;
grant execute on function public.shopping_pedido_finalizar_carrinho() to authenticated;
grant execute on function public.shopping_pagamento_mock_simular(uuid, public.shopping_status_pagamento, jsonb) to authenticated;
grant execute on function public.shopping_parceiro_listar_pedidos() to authenticated;
grant execute on function public.shopping_parceiro_confirmar_entrega(uuid, text) to authenticated;
grant execute on function public.shopping_cliente_confirmar_recebimento(uuid) to authenticated;
grant execute on function public.shopping_pedidos_cliente_listar() to authenticated;
grant execute on function public.shopping_admin_listar_pedidos() to authenticated;

grant execute on function public.shopping_pagamento_criar_entregas_pedido(uuid, timestamptz) to service_role;
grant execute on function public.shopping_pagamento_aplicar_resultado_provider(uuid, public.shopping_status_pagamento, text, jsonb, jsonb) to service_role;

comment on column public.shopping_produtos.parceiro_user_id is
  'Parceiro operacional responsavel por cumprir vendas futuras deste produto. Nullable para legado.';

comment on column public.shopping_produtos.valor_repasse_parceiro is
  'Valor unitario de repasse ao parceiro para vendas futuras. Snapshot e preservado no pedido.';

comment on table public.shopping_pedido_entregas is
  'Fulfillment por parceiro dentro do pedido. Separado de pagamento e repasse financeiro.';

comment on function public.shopping_parceiro_listar_pedidos() is
  'Lista somente pedidos pagos e itens do parceiro autenticado usando auth.uid().';

comment on function public.shopping_parceiro_confirmar_entrega(uuid, text) is
  'Permite ao parceiro autenticado confirmar envio ou entrega pessoal sem concluir o pedido.';

comment on function public.shopping_cliente_confirmar_recebimento(uuid) is
  'Cliente confirma recebimento; entrega vira recebido_cliente e repasse fica elegivel.';

notify pgrst, 'reload schema';
