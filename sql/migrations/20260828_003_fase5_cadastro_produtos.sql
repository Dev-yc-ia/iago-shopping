-- IAGO Shopping - Fase 5
-- Cadastro de produtos.
--
-- Escopo:
-- - cadastro administrativo de produtos com SKU, categoria, marca, preco e atributos;
-- - cadastro de imagens por URL, sem upload/storage nesta fase;
-- - CRUD administrativo auditado;
-- - catalogo publico preparado para ler produtos publicados;
-- - sem controle de estoque, carrinho, pedidos ou pagamentos.

do $$
begin
  create type public.shopping_status_produto as enum ('rascunho', 'publicado', 'arquivado');
exception
  when duplicate_object then null;
end
$$;

create table if not exists public.shopping_produtos (
  id uuid primary key default gen_random_uuid(),
  sku text not null unique,
  nome text not null,
  marca text not null,
  categoria text not null,
  preco numeric(12, 2) not null,
  destaque text,
  descricao text,
  atributos jsonb not null default '[]'::jsonb,
  status public.shopping_status_produto not null default 'rascunho',
  criado_por uuid references auth.users(id) on delete set null,
  atualizado_por uuid references auth.users(id) on delete set null,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint shopping_produtos_sku_not_blank check (btrim(sku) <> ''),
  constraint shopping_produtos_nome_not_blank check (btrim(nome) <> ''),
  constraint shopping_produtos_marca_not_blank check (btrim(marca) <> ''),
  constraint shopping_produtos_categoria_not_blank check (btrim(categoria) <> ''),
  constraint shopping_produtos_preco_non_negative check (preco >= 0),
  constraint shopping_produtos_atributos_array check (jsonb_typeof(atributos) = 'array')
);

create index if not exists idx_shopping_produtos_categoria_status
  on public.shopping_produtos (categoria, status);

create index if not exists idx_shopping_produtos_marca_status
  on public.shopping_produtos (marca, status);

create table if not exists public.shopping_produto_imagens (
  id uuid primary key default gen_random_uuid(),
  produto_id uuid not null references public.shopping_produtos(id) on delete cascade,
  url text not null,
  texto_alternativo text,
  ordem integer not null default 0,
  principal boolean not null default false,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint shopping_produto_imagens_url_not_blank check (btrim(url) <> ''),
  constraint shopping_produto_imagens_ordem_non_negative check (ordem >= 0)
);

create index if not exists idx_shopping_produto_imagens_produto_ordem
  on public.shopping_produto_imagens (produto_id, ordem, id);

drop trigger if exists trg_shopping_produtos_touch on public.shopping_produtos;
create trigger trg_shopping_produtos_touch
before update on public.shopping_produtos
for each row execute function public.shopping_touch_atualizado_em();

drop trigger if exists trg_shopping_produto_imagens_touch on public.shopping_produto_imagens;
create trigger trg_shopping_produto_imagens_touch
before update on public.shopping_produto_imagens
for each row execute function public.shopping_touch_atualizado_em();

alter table public.shopping_produtos enable row level security;
alter table public.shopping_produto_imagens enable row level security;

drop policy if exists shopping_produtos_select_public_or_admin on public.shopping_produtos;
create policy shopping_produtos_select_public_or_admin
on public.shopping_produtos
for select
to anon, authenticated
using (
  status = 'publicado'::public.shopping_status_produto
  or public.shopping_is_admin(auth.uid())
);

drop policy if exists shopping_produto_imagens_select_public_or_admin on public.shopping_produto_imagens;
create policy shopping_produto_imagens_select_public_or_admin
on public.shopping_produto_imagens
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

revoke all on public.shopping_produtos from anon, authenticated;
revoke all on public.shopping_produto_imagens from anon, authenticated;
grant select on public.shopping_produtos to anon, authenticated;
grant select on public.shopping_produto_imagens to anon, authenticated;

create or replace function public.shopping_admin_assert_produtos_permitido()
returns public.shopping_perfis
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_perfil public.shopping_perfis;
begin
  if auth.uid() is null then
    raise exception 'Operacao exige usuario autenticado.';
  end if;

  select *
  into v_perfil
  from public.shopping_perfis sp
  where sp.user_id = auth.uid()
    and sp.status_ativacao = 'ativo'::public.shopping_status_ativacao
    and sp.papel in (
      'master'::public.shopping_papel,
      'funcionario'::public.shopping_papel,
      'parceiro'::public.shopping_papel
    );

  if v_perfil.id is null then
    raise exception 'Perfil sem permissao para administrar produtos.';
  end if;

  return v_perfil;
end;
$$;

create or replace function public.shopping_admin_listar_produtos()
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
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'url', spi.url,
          'texto_alternativo', spi.texto_alternativo,
          'ordem', spi.ordem,
          'principal', spi.principal
        )
        order by spi.ordem, spi.id
      ) filter (where spi.id is not null),
      '[]'::jsonb
    ) as imagens,
    sp.status,
    sp.criado_por,
    sp.criado_em,
    sp.atualizado_em
  from public.shopping_produtos sp
  left join public.shopping_produto_imagens spi on spi.produto_id = sp.id
  where v_perfil.papel <> 'parceiro'::public.shopping_papel
     or sp.criado_por = auth.uid()
  group by sp.id
  order by sp.atualizado_em desc, sp.nome;
end;
$$;

create or replace function public.shopping_catalogo_produtos_publicados()
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
  status public.shopping_status_produto
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
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'url', spi.url,
          'texto_alternativo', spi.texto_alternativo,
          'ordem', spi.ordem,
          'principal', spi.principal
        )
        order by spi.ordem, spi.id
      ) filter (where spi.id is not null),
      '[]'::jsonb
    ) as imagens,
    sp.status
  from public.shopping_produtos sp
  left join public.shopping_produto_imagens spi on spi.produto_id = sp.id
  where sp.status = 'publicado'::public.shopping_status_produto
  group by sp.id
  order by sp.atualizado_em desc, sp.nome;
$$;

create or replace function public.shopping_admin_salvar_produto(
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
  p_status public.shopping_status_produto default 'rascunho'
)
returns public.shopping_produtos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_perfil public.shopping_perfis := public.shopping_admin_assert_produtos_permitido();
  v_antes jsonb;
  v_produto public.shopping_produtos;
begin
  if p_sku is null or btrim(p_sku) = '' then
    raise exception 'SKU e obrigatorio.';
  end if;

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

  if p_atributos is null or jsonb_typeof(p_atributos) <> 'array' then
    raise exception 'Atributos devem ser uma lista JSON.';
  end if;

  if p_imagens is null or jsonb_typeof(p_imagens) <> 'array' then
    raise exception 'Imagens devem ser uma lista JSON.';
  end if;

  if p_id is null then
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
      criado_por,
      atualizado_por
    )
    values (
      upper(btrim(p_sku)),
      btrim(p_nome),
      btrim(p_marca),
      btrim(p_categoria),
      p_preco,
      nullif(btrim(p_destaque), ''),
      nullif(btrim(p_descricao), ''),
      p_atributos,
      p_status,
      auth.uid(),
      auth.uid()
    )
    returning * into v_produto;
  else
    select to_jsonb(sp.*)
    into v_antes
    from public.shopping_produtos sp
    where sp.id = p_id
    for update;

    if v_antes is null then
      raise exception 'Produto nao encontrado.';
    end if;

    if v_perfil.papel = 'parceiro'::public.shopping_papel
      and (v_antes ->> 'criado_por')::uuid is distinct from auth.uid() then
      raise exception 'Parceiro so pode editar produtos criados por ele.';
    end if;

    update public.shopping_produtos
    set sku = upper(btrim(p_sku)),
        nome = btrim(p_nome),
        marca = btrim(p_marca),
        categoria = btrim(p_categoria),
        preco = p_preco,
        destaque = nullif(btrim(p_destaque), ''),
        descricao = nullif(btrim(p_descricao), ''),
        atributos = p_atributos,
        status = p_status,
        atualizado_por = auth.uid()
    where id = p_id
    returning * into v_produto;
  end if;

  delete from public.shopping_produto_imagens
  where produto_id = v_produto.id;

  insert into public.shopping_produto_imagens (
    produto_id,
    url,
    texto_alternativo,
    ordem,
    principal
  )
  select
    v_produto.id,
    btrim(imagem.url),
    nullif(btrim(imagem.texto_alternativo), ''),
    coalesce(imagem.ordem, 0),
    coalesce(imagem.principal, false)
  from jsonb_to_recordset(p_imagens) as imagem(
    url text,
    texto_alternativo text,
    ordem integer,
    principal boolean
  )
  where nullif(btrim(imagem.url), '') is not null;

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
    'Cadastro de produto pela Fase 5 do IAGO Shopping.'
  );

  return v_produto;
end;
$$;

create or replace function public.shopping_admin_excluir_produto(
  p_id uuid,
  p_motivo text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_perfil public.shopping_perfis := public.shopping_admin_assert_produtos_permitido();
  v_antes jsonb;
begin
  if p_motivo is null or btrim(p_motivo) = '' then
    raise exception 'Motivo e obrigatorio para auditoria.';
  end if;

  select to_jsonb(sp.*)
  into v_antes
  from public.shopping_produtos sp
  where sp.id = p_id
  for update;

  if v_antes is null then
    raise exception 'Produto nao encontrado.';
  end if;

  if v_perfil.papel = 'parceiro'::public.shopping_papel
    and (v_antes ->> 'criado_por')::uuid is distinct from auth.uid() then
    raise exception 'Parceiro so pode excluir produtos criados por ele.';
  end if;

  delete from public.shopping_produtos
  where id = p_id;

  insert into public.shopping_auditoria (
    ator_user_id,
    acao,
    tabela,
    registro_id,
    antes,
    motivo
  )
  values (
    auth.uid(),
    'produto.excluir',
    'shopping_produtos',
    p_id,
    v_antes,
    p_motivo
  );
end;
$$;

revoke all on function public.shopping_admin_assert_produtos_permitido() from public, anon, authenticated;
revoke all on function public.shopping_admin_listar_produtos() from public, anon, authenticated;
revoke all on function public.shopping_catalogo_produtos_publicados() from public, anon, authenticated;
revoke all on function public.shopping_admin_salvar_produto(
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
  public.shopping_status_produto
) from public, anon, authenticated;
revoke all on function public.shopping_admin_excluir_produto(uuid, text) from public, anon, authenticated;

grant execute on function public.shopping_admin_listar_produtos() to authenticated;
grant execute on function public.shopping_catalogo_produtos_publicados() to anon, authenticated;
grant execute on function public.shopping_admin_salvar_produto(
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
  public.shopping_status_produto
) to authenticated;
grant execute on function public.shopping_admin_excluir_produto(uuid, text) to authenticated;

comment on table public.shopping_produtos is
  'Cadastro de produtos do IAGO Shopping. Sem controle de estoque nesta fase.';

comment on table public.shopping_produto_imagens is
  'Imagens de produtos cadastradas por URL. Upload/storage ficam fora da Fase 5.';

comment on function public.shopping_admin_salvar_produto(
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
  public.shopping_status_produto
) is
  'Cria ou atualiza produto com SKU, preco, atributos e imagens por URL.';
