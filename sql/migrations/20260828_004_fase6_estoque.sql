-- IAGO Shopping - Fase 6
-- Estoque por variacao com lancamento junto ao cadastro de produtos.
--
-- Escopo:
-- - tabela de variacoes com saldo atual;
-- - historico auditavel de movimentacoes de estoque;
-- - RPC administrativa para salvar produto com estoque inicial/ajuste;
-- - catalogo publico lendo produtos publicados com saldo real;
-- - sem carrinho, pedidos, pagamentos ou baixa automatica por venda nesta fase.

do $$
begin
  create type public.shopping_tipo_movimento_estoque as enum (
    'entrada_inicial',
    'ajuste_admin',
    'venda',
    'cancelamento'
  );
exception
  when duplicate_object then null;
end
$$;

create table if not exists public.shopping_produto_variacoes (
  id uuid primary key default gen_random_uuid(),
  produto_id uuid not null references public.shopping_produtos(id) on delete cascade,
  sku_variacao text not null,
  nome_variacao text not null default 'Padrao',
  atributos jsonb not null default '{}'::jsonb,
  estoque_atual integer not null default 0,
  principal boolean not null default false,
  ativo boolean not null default true,
  criado_por uuid references auth.users(id) on delete set null,
  atualizado_por uuid references auth.users(id) on delete set null,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint shopping_produto_variacoes_sku_not_blank check (btrim(sku_variacao) <> ''),
  constraint shopping_produto_variacoes_nome_not_blank check (btrim(nome_variacao) <> ''),
  constraint shopping_produto_variacoes_atributos_object check (jsonb_typeof(atributos) = 'object'),
  constraint shopping_produto_variacoes_estoque_non_negative check (estoque_atual >= 0),
  constraint shopping_produto_variacoes_sku_unique unique (produto_id, sku_variacao)
);

create unique index if not exists idx_shopping_produto_variacoes_principal
  on public.shopping_produto_variacoes (produto_id)
  where principal;

create index if not exists idx_shopping_produto_variacoes_produto_ativo
  on public.shopping_produto_variacoes (produto_id, ativo);

create table if not exists public.shopping_estoque_movimentos (
  id bigint generated always as identity primary key,
  variacao_id uuid not null references public.shopping_produto_variacoes(id) on delete cascade,
  produto_id uuid not null references public.shopping_produtos(id) on delete cascade,
  tipo public.shopping_tipo_movimento_estoque not null,
  quantidade integer not null,
  saldo_anterior integer not null,
  saldo_posterior integer not null,
  motivo text,
  criado_por uuid references auth.users(id) on delete set null,
  criado_em timestamptz not null default now(),
  constraint shopping_estoque_movimentos_quantidade_not_zero check (quantidade <> 0),
  constraint shopping_estoque_movimentos_saldo_anterior_non_negative check (saldo_anterior >= 0),
  constraint shopping_estoque_movimentos_saldo_posterior_non_negative check (saldo_posterior >= 0)
);

create index if not exists idx_shopping_estoque_movimentos_variacao_data
  on public.shopping_estoque_movimentos (variacao_id, criado_em desc);

create index if not exists idx_shopping_estoque_movimentos_produto_data
  on public.shopping_estoque_movimentos (produto_id, criado_em desc);

drop trigger if exists trg_shopping_produto_variacoes_touch on public.shopping_produto_variacoes;
create trigger trg_shopping_produto_variacoes_touch
before update on public.shopping_produto_variacoes
for each row execute function public.shopping_touch_atualizado_em();

alter table public.shopping_produto_variacoes enable row level security;
alter table public.shopping_estoque_movimentos enable row level security;

drop policy if exists shopping_produto_variacoes_select_public_or_admin on public.shopping_produto_variacoes;
create policy shopping_produto_variacoes_select_public_or_admin
on public.shopping_produto_variacoes
for select
to anon, authenticated
using (
  exists (
    select 1
    from public.shopping_produtos sp
    where sp.id = produto_id
      and (
        sp.status = 'publicado'::public.shopping_status_produto
        or public.shopping_is_admin(auth.uid())
      )
  )
);

drop policy if exists shopping_estoque_movimentos_select_admin on public.shopping_estoque_movimentos;
create policy shopping_estoque_movimentos_select_admin
on public.shopping_estoque_movimentos
for select
to authenticated
using (public.shopping_is_admin(auth.uid()));

revoke all on public.shopping_produto_variacoes from anon, authenticated;
revoke all on public.shopping_estoque_movimentos from anon, authenticated;

insert into public.shopping_produto_variacoes (
  produto_id,
  sku_variacao,
  nome_variacao,
  principal,
  estoque_atual
)
select
  sp.id,
  sp.sku || '-PADRAO',
  'Padrao',
  true,
  0
from public.shopping_produtos sp
where not exists (
  select 1
  from public.shopping_produto_variacoes spv
  where spv.produto_id = sp.id
    and spv.principal
);

create or replace function public.shopping_admin_definir_estoque_produto(
  p_produto_id uuid,
  p_quantidade_estoque integer,
  p_motivo text default null
)
returns public.shopping_produto_variacoes
language plpgsql
security definer
set search_path = public
as $$
declare
  v_perfil public.shopping_perfis := public.shopping_admin_assert_produtos_permitido();
  v_produto public.shopping_produtos;
  v_variacao public.shopping_produto_variacoes;
  v_saldo_anterior integer;
  v_delta integer;
  v_tipo public.shopping_tipo_movimento_estoque;
begin
  if p_quantidade_estoque is null or p_quantidade_estoque < 0 then
    raise exception 'Quantidade em estoque deve ser maior ou igual a zero.';
  end if;

  select *
  into v_produto
  from public.shopping_produtos sp
  where sp.id = p_produto_id
  for update;

  if v_produto.id is null then
    raise exception 'Produto nao encontrado para controle de estoque.';
  end if;

  if v_perfil.papel = 'parceiro'::public.shopping_papel
    and v_produto.criado_por is distinct from auth.uid() then
    raise exception 'Parceiro so pode ajustar estoque de produtos criados por ele.';
  end if;

  select *
  into v_variacao
  from public.shopping_produto_variacoes spv
  where spv.produto_id = v_produto.id
    and spv.principal
  for update;

  if v_variacao.id is null then
    insert into public.shopping_produto_variacoes (
      produto_id,
      sku_variacao,
      nome_variacao,
      principal,
      estoque_atual,
      criado_por,
      atualizado_por
    )
    values (
      v_produto.id,
      v_produto.sku || '-PADRAO',
      'Padrao',
      true,
      0,
      auth.uid(),
      auth.uid()
    )
    returning * into v_variacao;
  end if;

  v_saldo_anterior := v_variacao.estoque_atual;
  v_delta := p_quantidade_estoque - v_saldo_anterior;

  update public.shopping_produto_variacoes
  set sku_variacao = v_produto.sku || '-PADRAO',
      estoque_atual = p_quantidade_estoque,
      ativo = true,
      atualizado_por = auth.uid()
  where id = v_variacao.id
  returning * into v_variacao;

  if v_delta <> 0 then
    v_tipo := case
      when v_saldo_anterior = 0 and v_delta > 0 then 'entrada_inicial'::public.shopping_tipo_movimento_estoque
      else 'ajuste_admin'::public.shopping_tipo_movimento_estoque
    end;

    insert into public.shopping_estoque_movimentos (
      variacao_id,
      produto_id,
      tipo,
      quantidade,
      saldo_anterior,
      saldo_posterior,
      motivo,
      criado_por
    )
    values (
      v_variacao.id,
      v_produto.id,
      v_tipo,
      v_delta,
      v_saldo_anterior,
      p_quantidade_estoque,
      coalesce(nullif(btrim(p_motivo), ''), 'Lancamento de estoque pela Fase 6 do IAGO Shopping.'),
      auth.uid()
    );
  end if;

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
    'estoque.ajustar',
    'shopping_produto_variacoes',
    v_variacao.id,
    jsonb_build_object('estoque_atual', v_saldo_anterior),
    to_jsonb(v_variacao),
    coalesce(nullif(btrim(p_motivo), ''), 'Ajuste de estoque pela Fase 6 do IAGO Shopping.')
  );

  return v_variacao;
end;
$$;

create or replace function public.shopping_admin_salvar_produto_com_estoque(
  p_id uuid,
  p_sku text,
  p_nome text,
  p_marca text,
  p_categoria text,
  p_preco numeric,
  p_destaque text default null,
  p_descricao text default null,
  p_atributos jsonb default '[]'::jsonb,
  p_imagens jsonb default '[]'::jsonb,
  p_status public.shopping_status_produto default 'rascunho',
  p_quantidade_estoque integer default 0
)
returns public.shopping_produtos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_produto public.shopping_produtos;
  v_variacao public.shopping_produto_variacoes;
begin
  v_produto := public.shopping_admin_salvar_produto(
    p_id,
    p_sku,
    p_nome,
    p_marca,
    p_categoria,
    p_preco,
    p_destaque,
    p_descricao,
    p_atributos,
    p_imagens,
    p_status
  );

  v_variacao := public.shopping_admin_definir_estoque_produto(
    v_produto.id,
    p_quantidade_estoque,
    'Lancamento junto ao cadastro de produto pela Fase 6 do IAGO Shopping.'
  );

  return v_produto;
end;
$$;

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
    sp.criado_por,
    sp.criado_em,
    sp.atualizado_em
  from public.shopping_produtos sp
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
     or sp.criado_por = auth.uid()
  order by sp.atualizado_em desc, sp.nome;
end;
$$;

create or replace function public.shopping_catalogo_produtos_publicados_com_estoque()
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
  quantidade_estoque integer
)
language sql
stable
security definer
set search_path = public
as $$
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
    se.quantidade_estoque
  from public.shopping_produtos sp
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
  where sp.status = 'publicado'::public.shopping_status_produto
  order by sp.atualizado_em desc, sp.nome;
$$;

revoke all on function public.shopping_admin_definir_estoque_produto(uuid, integer, text) from public, anon, authenticated;
revoke all on function public.shopping_admin_salvar_produto_com_estoque(
  uuid,
  text,
  text,
  text,
  text,
  numeric,
  text,
  text,
  jsonb,
  jsonb,
  public.shopping_status_produto,
  integer
) from public, anon, authenticated;
revoke all on function public.shopping_admin_listar_produtos_com_estoque() from public, anon, authenticated;
revoke all on function public.shopping_catalogo_produtos_publicados_com_estoque() from public, anon, authenticated;

grant execute on function public.shopping_admin_definir_estoque_produto(uuid, integer, text) to authenticated;
grant execute on function public.shopping_admin_salvar_produto_com_estoque(
  uuid,
  text,
  text,
  text,
  text,
  numeric,
  text,
  text,
  jsonb,
  jsonb,
  public.shopping_status_produto,
  integer
) to authenticated;
grant execute on function public.shopping_admin_listar_produtos_com_estoque() to authenticated;
grant execute on function public.shopping_catalogo_produtos_publicados_com_estoque() to anon, authenticated;

comment on table public.shopping_produtos is
  'Cadastro de produtos do IAGO Shopping com estoque real por variacao a partir da Fase 6.';

comment on table public.shopping_produto_variacoes is
  'Variacoes de produto com saldo atual de estoque. No MVP, o cadastro usa uma variacao principal padrao.';

comment on table public.shopping_estoque_movimentos is
  'Historico auditavel de entradas e ajustes de estoque. Baixa automatica por venda fica para fases futuras.';

comment on function public.shopping_admin_salvar_produto_com_estoque(
  uuid,
  text,
  text,
  text,
  text,
  numeric,
  text,
  text,
  jsonb,
  jsonb,
  public.shopping_status_produto,
  integer
) is
  'Cria ou atualiza produto e registra o saldo de estoque da variacao principal no mesmo fluxo administrativo.';
