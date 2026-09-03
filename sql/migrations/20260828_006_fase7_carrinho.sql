-- Fase 7 - Carrinho por usuario autenticado.
--
-- Escopo:
-- - carrinho ativo por usuario logado;
-- - itens vinculados a produtos publicados;
-- - validacao de estoque disponivel sem baixa automatica;
-- - sem pedidos, pagamentos ou conversao de venda nesta fase.

do $$
begin
  create type public.shopping_status_carrinho as enum ('ativo', 'convertido', 'cancelado');
exception
  when duplicate_object then null;
end;
$$;

create table if not exists public.shopping_carrinhos (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  status public.shopping_status_carrinho not null default 'ativo',
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint shopping_carrinhos_user_id_not_empty check (user_id is not null)
);

create unique index if not exists idx_shopping_carrinhos_usuario_ativo
  on public.shopping_carrinhos (user_id)
  where status = 'ativo'::public.shopping_status_carrinho;

create index if not exists idx_shopping_carrinhos_user_status
  on public.shopping_carrinhos (user_id, status);

create table if not exists public.shopping_carrinho_itens (
  id uuid primary key default gen_random_uuid(),
  carrinho_id uuid not null references public.shopping_carrinhos(id) on delete cascade,
  produto_id uuid not null references public.shopping_produtos(id) on delete cascade,
  quantidade integer not null default 1,
  preco_unitario numeric(12, 2) not null,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint shopping_carrinho_itens_quantidade_positive check (quantidade > 0),
  constraint shopping_carrinho_itens_preco_non_negative check (preco_unitario >= 0),
  constraint shopping_carrinho_itens_unique_produto unique (carrinho_id, produto_id)
);

create index if not exists idx_shopping_carrinho_itens_carrinho
  on public.shopping_carrinho_itens (carrinho_id, atualizado_em desc);

create index if not exists idx_shopping_carrinho_itens_produto
  on public.shopping_carrinho_itens (produto_id);

drop trigger if exists trg_shopping_carrinhos_touch on public.shopping_carrinhos;
create trigger trg_shopping_carrinhos_touch
before update on public.shopping_carrinhos
for each row execute function public.shopping_touch_atualizado_em();

drop trigger if exists trg_shopping_carrinho_itens_touch on public.shopping_carrinho_itens;
create trigger trg_shopping_carrinho_itens_touch
before update on public.shopping_carrinho_itens
for each row execute function public.shopping_touch_atualizado_em();

alter table public.shopping_carrinhos enable row level security;
alter table public.shopping_carrinho_itens enable row level security;

drop policy if exists shopping_carrinhos_select_own on public.shopping_carrinhos;
create policy shopping_carrinhos_select_own
on public.shopping_carrinhos
for select
to authenticated
using (user_id = auth.uid());

drop policy if exists shopping_carrinho_itens_select_own on public.shopping_carrinho_itens;
create policy shopping_carrinho_itens_select_own
on public.shopping_carrinho_itens
for select
to authenticated
using (
  exists (
    select 1
    from public.shopping_carrinhos sc
    where sc.id = carrinho_id
      and sc.user_id = auth.uid()
  )
);

revoke all on public.shopping_carrinhos from anon, authenticated;
revoke all on public.shopping_carrinho_itens from anon, authenticated;

create or replace function public.shopping_carrinho_assert_user()
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Faca login para montar seu carrinho.';
  end if;

  if not exists (
    select 1
    from public.shopping_perfis sp
    where sp.user_id = v_user_id
  ) then
    raise exception 'Perfil do usuario nao encontrado para o carrinho.';
  end if;

  return v_user_id;
end;
$$;

create or replace function public.shopping_carrinho_ativo_id()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := public.shopping_carrinho_assert_user();
  v_carrinho_id uuid;
begin
  select sc.id
  into v_carrinho_id
  from public.shopping_carrinhos sc
  where sc.user_id = v_user_id
    and sc.status = 'ativo'::public.shopping_status_carrinho
  limit 1;

  if v_carrinho_id is not null then
    return v_carrinho_id;
  end if;

  begin
    insert into public.shopping_carrinhos (user_id)
    values (v_user_id)
    returning id into v_carrinho_id;
  exception
    when unique_violation then
      select sc.id
      into v_carrinho_id
      from public.shopping_carrinhos sc
      where sc.user_id = v_user_id
        and sc.status = 'ativo'::public.shopping_status_carrinho
      limit 1;
  end;

  return v_carrinho_id;
end;
$$;

create or replace function public.shopping_carrinho_atual()
returns table (
  carrinho_id uuid,
  item_id uuid,
  produto_id uuid,
  sku text,
  nome text,
  marca text,
  categoria text,
  preco_unitario numeric,
  quantidade integer,
  subtotal numeric,
  estoque_disponivel integer,
  imagens jsonb,
  atualizado_em timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_carrinho_id uuid := public.shopping_carrinho_ativo_id();
begin
  return query
  select
    v_carrinho_id as carrinho_id,
    sci.id as item_id,
    sp.id as produto_id,
    sp.sku,
    sp.nome,
    sp.marca,
    sp.categoria,
    sci.preco_unitario,
    sci.quantidade,
    (sci.preco_unitario * sci.quantidade)::numeric as subtotal,
    se.estoque_disponivel,
    si.imagens,
    sci.atualizado_em
  from public.shopping_carrinho_itens sci
  join public.shopping_produtos sp on sp.id = sci.produto_id
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
    select coalesce(sum(spv.estoque_atual) filter (where spv.ativo), 0)::integer as estoque_disponivel
    from public.shopping_produto_variacoes spv
    where spv.produto_id = sp.id
  ) se on true
  where sci.carrinho_id = v_carrinho_id
  order by sci.atualizado_em desc, sci.criado_em desc;
end;
$$;

create or replace function public.shopping_carrinho_adicionar_produto(
  p_produto_id uuid,
  p_quantidade integer default 1
)
returns public.shopping_carrinho_itens
language plpgsql
security definer
set search_path = public
as $$
declare
  v_carrinho_id uuid := public.shopping_carrinho_ativo_id();
  v_produto public.shopping_produtos;
  v_item public.shopping_carrinho_itens;
  v_estoque integer;
  v_quantidade_atual integer := 0;
  v_quantidade_final integer;
begin
  if p_produto_id is null then
    raise exception 'Produto obrigatorio para adicionar ao carrinho.';
  end if;

  if p_quantidade is null or p_quantidade <= 0 then
    raise exception 'Quantidade deve ser maior que zero.';
  end if;

  select *
  into v_produto
  from public.shopping_produtos sp
  where sp.id = p_produto_id
    and sp.status = 'publicado'::public.shopping_status_produto;

  if v_produto.id is null then
    raise exception 'Produto indisponivel para compra.';
  end if;

  select coalesce(sum(spv.estoque_atual) filter (where spv.ativo), 0)::integer
  into v_estoque
  from public.shopping_produto_variacoes spv
  where spv.produto_id = v_produto.id;

  if v_estoque <= 0 then
    raise exception 'Produto sem estoque disponivel.';
  end if;

  select coalesce(sci.quantidade, 0)
  into v_quantidade_atual
  from public.shopping_carrinho_itens sci
  where sci.carrinho_id = v_carrinho_id
    and sci.produto_id = v_produto.id
  for update;

  v_quantidade_final := coalesce(v_quantidade_atual, 0) + p_quantidade;

  if v_quantidade_final > v_estoque then
    raise exception 'Quantidade solicitada maior que o estoque disponivel.';
  end if;

  insert into public.shopping_carrinho_itens (
    carrinho_id,
    produto_id,
    quantidade,
    preco_unitario
  )
  values (
    v_carrinho_id,
    v_produto.id,
    p_quantidade,
    v_produto.preco
  )
  on conflict (carrinho_id, produto_id)
  do update
  set quantidade = v_quantidade_final,
      preco_unitario = excluded.preco_unitario
  returning * into v_item;

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
    'carrinho.adicionar',
    'shopping_carrinho_itens',
    v_item.id,
    null,
    to_jsonb(v_item),
    'Produto adicionado ao carrinho pela Fase 7 do IAGO Shopping.'
  );

  return v_item;
end;
$$;

create or replace function public.shopping_carrinho_definir_quantidade(
  p_item_id uuid,
  p_quantidade integer
)
returns public.shopping_carrinho_itens
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := public.shopping_carrinho_assert_user();
  v_item public.shopping_carrinho_itens;
  v_estoque integer;
begin
  if p_item_id is null then
    raise exception 'Item obrigatorio para atualizar o carrinho.';
  end if;

  if p_quantidade is null or p_quantidade <= 0 then
    raise exception 'Quantidade deve ser maior que zero.';
  end if;

  select sci.*
  into v_item
  from public.shopping_carrinho_itens sci
  join public.shopping_carrinhos sc on sc.id = sci.carrinho_id
  where sci.id = p_item_id
    and sc.user_id = v_user_id
    and sc.status = 'ativo'::public.shopping_status_carrinho
  for update;

  if v_item.id is null then
    raise exception 'Item nao encontrado no carrinho ativo.';
  end if;

  select coalesce(sum(spv.estoque_atual) filter (where spv.ativo), 0)::integer
  into v_estoque
  from public.shopping_produto_variacoes spv
  where spv.produto_id = v_item.produto_id;

  if p_quantidade > v_estoque then
    raise exception 'Quantidade solicitada maior que o estoque disponivel.';
  end if;

  update public.shopping_carrinho_itens
  set quantidade = p_quantidade
  where id = v_item.id
  returning * into v_item;

  return v_item;
end;
$$;

create or replace function public.shopping_carrinho_remover_item(p_item_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := public.shopping_carrinho_assert_user();
begin
  delete from public.shopping_carrinho_itens sci
  using public.shopping_carrinhos sc
  where sci.id = p_item_id
    and sc.id = sci.carrinho_id
    and sc.user_id = v_user_id
    and sc.status = 'ativo'::public.shopping_status_carrinho;
end;
$$;

revoke all on function public.shopping_carrinho_assert_user() from public, anon, authenticated;
revoke all on function public.shopping_carrinho_ativo_id() from public, anon, authenticated;
revoke all on function public.shopping_carrinho_atual() from public, anon, authenticated;
revoke all on function public.shopping_carrinho_adicionar_produto(uuid, integer) from public, anon, authenticated;
revoke all on function public.shopping_carrinho_definir_quantidade(uuid, integer) from public, anon, authenticated;
revoke all on function public.shopping_carrinho_remover_item(uuid) from public, anon, authenticated;

grant execute on function public.shopping_carrinho_atual() to authenticated;
grant execute on function public.shopping_carrinho_adicionar_produto(uuid, integer) to authenticated;
grant execute on function public.shopping_carrinho_definir_quantidade(uuid, integer) to authenticated;
grant execute on function public.shopping_carrinho_remover_item(uuid) to authenticated;

comment on table public.shopping_carrinhos is
  'Carrinho ativo por usuario autenticado do IAGO Shopping. Conversao em pedido fica fora da Fase 7.';

comment on table public.shopping_carrinho_itens is
  'Itens do carrinho por produto publicado, sem baixa automatica de estoque nesta fase.';

comment on function public.shopping_carrinho_atual() is
  'Retorna os itens do carrinho ativo do usuario autenticado.';

comment on function public.shopping_carrinho_adicionar_produto(uuid, integer) is
  'Adiciona produto publicado ao carrinho ativo do usuario autenticado, validando estoque disponivel.';
