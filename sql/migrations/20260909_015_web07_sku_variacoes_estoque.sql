-- WEB-07 - SKU automatico e variacoes de estoque.
--
-- Escopo:
-- - SKU definitivo gerado no Supabase com trava transacional por prefixo;
-- - reutilizacao de shopping_produto_variacoes para tamanhos/variacoes flexiveis;
-- - carrinho chaveado por produto + variacao;
-- - pedido e listagens preservando variacao_id e nome da variacao;
-- - estoque sempre validado server-side na variacao correta.

create or replace function public.shopping_sku_codigo_categoria(p_categoria text)
returns text
language sql
immutable
set search_path = public
as $$
  select case lower(coalesce(p_categoria, ''))
    when 'shapes' then 'SHA'
    when 'rodas' then 'ROD'
    when 'tenis' then 'TEN'
    when 'roupas-camisas' then 'ROU'
    when 'cameras-acessorios' then 'CAM'
    else upper(left(regexp_replace(coalesce(p_categoria, ''), '[^[:alnum:]]+', '', 'g'), 3))
  end;
$$;

create or replace function public.shopping_normalizar_codigo(p_valor text)
returns text
language sql
immutable
set search_path = public
as $$
  select coalesce(
    nullif(
      regexp_replace(
        translate(
          upper(btrim(coalesce(p_valor, ''))),
          'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
          'AAAAAEEEEIIIIOOOOOUUUUCN'
        ),
        '[^A-Z0-9]+',
        '',
        'g'
      ),
      ''
    ),
    'IAGO'
  );
$$;

create or replace function public.shopping_variacao_normalizar_valor(p_valor text)
returns text
language sql
immutable
set search_path = public
as $$
  select lower(regexp_replace(btrim(coalesce(p_valor, '')), '\s+', ' ', 'g'));
$$;

create or replace function public.shopping_variacao_sku_segmento(p_valor text)
returns text
language sql
immutable
set search_path = public
as $$
  select coalesce(
    nullif(
      regexp_replace(
        replace(
          replace(public.shopping_normalizar_codigo(p_valor), '/', '-'),
          '.',
          'P'
        ),
        '[^A-Z0-9-]+',
        '',
        'g'
      ),
      ''
    ),
    'VAR'
  );
$$;

create or replace function public.shopping_gerar_sku_produto(
  p_categoria text,
  p_marca text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_categoria text := public.shopping_sku_codigo_categoria(p_categoria);
  v_marca text := public.shopping_normalizar_codigo(p_marca);
  v_prefixo text;
  v_sequencial integer;
begin
  if v_categoria is null or length(v_categoria) <> 3 then
    raise exception 'Categoria invalida para geracao de SKU.';
  end if;

  v_prefixo := v_categoria || '-' || v_marca || '-';

  perform pg_advisory_xact_lock(hashtext('shopping_sku:' || v_prefixo));

  select coalesce(max((regexp_match(sp.sku, '^' || v_prefixo || '([0-9]{3,})$'))[1]::integer), 0) + 1
  into v_sequencial
  from public.shopping_produtos sp
  where sp.sku like v_prefixo || '%';

  return v_prefixo || lpad(v_sequencial::text, 3, '0');
end;
$$;

alter table public.shopping_carrinho_itens
  add column if not exists variacao_id uuid references public.shopping_produto_variacoes(id) on delete set null;

update public.shopping_carrinho_itens sci
set variacao_id = spv.id
from public.shopping_produto_variacoes spv
where sci.variacao_id is null
  and spv.produto_id = sci.produto_id
  and spv.ativo
  and spv.principal;

update public.shopping_carrinho_itens sci
set variacao_id = (
  select spv_inner.id
  from public.shopping_produto_variacoes spv_inner
  where spv_inner.produto_id = sci.produto_id
    and spv_inner.ativo
  order by spv_inner.principal desc, spv_inner.criado_em, spv_inner.id
  limit 1
)
where sci.variacao_id is null
  and exists (
    select 1
    from public.shopping_produto_variacoes spv_inner
    where spv_inner.produto_id = sci.produto_id
      and spv_inner.ativo
  );

alter table public.shopping_carrinho_itens
  drop constraint if exists shopping_carrinho_itens_unique_produto;

create unique index if not exists idx_shopping_carrinho_itens_unique_produto_variacao
  on public.shopping_carrinho_itens (
    carrinho_id,
    produto_id,
    coalesce(variacao_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );

create index if not exists idx_shopping_carrinho_itens_variacao
  on public.shopping_carrinho_itens (variacao_id);

create unique index if not exists idx_shopping_produto_variacoes_nome_ativo_unique
  on public.shopping_produto_variacoes (
    produto_id,
    public.shopping_variacao_normalizar_valor(nome_variacao)
  )
  where ativo;

create or replace function public.shopping_variacoes_json(p_produto_id uuid, p_apenas_ativas boolean default true)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', spv.id,
        'sku_variacao', spv.sku_variacao,
        'nome_variacao', spv.nome_variacao,
        'estoque_atual', spv.estoque_atual,
        'principal', spv.principal,
        'ativo', spv.ativo,
        'ordem', coalesce((spv.atributos ->> 'ordem_grade')::integer, 0)
      )
      order by
        coalesce((spv.atributos ->> 'ordem_grade')::integer, 0),
        case public.shopping_variacao_normalizar_valor(spv.nome_variacao)
          when 'pp' then 1
          when 'p' then 2
          when 'm' then 3
          when 'g' then 4
          when 'gg' then 5
          when 'xg' then 6
          when 'xgg' then 7
          else 99
        end,
        spv.nome_variacao
    ),
    '[]'::jsonb
  )
  from public.shopping_produto_variacoes spv
  where spv.produto_id = p_produto_id
    and (not p_apenas_ativas or spv.ativo);
$$;

drop function if exists public.shopping_admin_sincronizar_variacoes_produto(uuid, jsonb, text);
create or replace function public.shopping_admin_sincronizar_variacoes_produto(
  p_produto_id uuid,
  p_variacoes jsonb default '[]'::jsonb,
  p_motivo text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_produto public.shopping_produtos;
  v_item jsonb;
  v_variacao public.shopping_produto_variacoes;
  v_nome text;
  v_chave text;
  v_sku_variacao text;
  v_estoque integer;
  v_ordem integer := 0;
  v_saldo_anterior integer;
  v_delta integer;
  v_seen text[] := array[]::text[];
  v_keep_ids uuid[] := array[]::uuid[];
  v_removida public.shopping_produto_variacoes;
begin
  if p_variacoes is null or jsonb_typeof(p_variacoes) <> 'array' then
    raise exception 'Variacoes devem ser enviadas como lista.';
  end if;

  select *
  into v_produto
  from public.shopping_produtos sp
  where sp.id = p_produto_id
  for update;

  if v_produto.id is null then
    raise exception 'Produto nao encontrado para sincronizar variacoes.';
  end if;

  update public.shopping_produto_variacoes
  set principal = false
  where produto_id = v_produto.id;

  for v_item in select * from jsonb_array_elements(p_variacoes)
  loop
    v_nome := btrim(coalesce(
      v_item ->> 'nome_variacao',
      v_item ->> 'valor',
      v_item ->> 'tamanho',
      ''
    ));
    v_chave := public.shopping_variacao_normalizar_valor(v_nome);
    v_estoque := nullif(coalesce(v_item ->> 'estoque_atual', v_item ->> 'estoque', ''), '')::integer;

    if v_nome = '' then
      raise exception 'Tamanho/variacao nao pode ficar vazio.';
    end if;

    if v_estoque is null or v_estoque < 0 then
      raise exception 'Estoque da variacao deve ser maior ou igual a zero.';
    end if;

    if v_chave = any(v_seen) then
      raise exception 'Variacao duplicada no mesmo produto: %.', v_nome;
    end if;
    v_seen := array_append(v_seen, v_chave);

    select *
    into v_variacao
    from public.shopping_produto_variacoes spv
    where spv.produto_id = v_produto.id
      and (
        spv.id = nullif(v_item ->> 'id', '')::uuid
        or public.shopping_variacao_normalizar_valor(spv.nome_variacao) = v_chave
      )
    order by spv.ativo desc, spv.criado_em
    limit 1
    for update;

    v_sku_variacao := v_produto.sku || '-' || public.shopping_variacao_sku_segmento(v_nome);

    if v_variacao.id is null then
      insert into public.shopping_produto_variacoes (
        produto_id,
        sku_variacao,
        nome_variacao,
        atributos,
        estoque_atual,
        principal,
        ativo,
        criado_por,
        atualizado_por
      )
      values (
        v_produto.id,
        v_sku_variacao,
        v_nome,
        jsonb_build_object('ordem_grade', v_ordem),
        v_estoque,
        false,
        true,
        auth.uid(),
        auth.uid()
      )
      returning * into v_variacao;

      if v_estoque <> 0 then
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
          'entrada_inicial'::public.shopping_tipo_movimento_estoque,
          v_estoque,
          0,
          v_estoque,
          coalesce(nullif(btrim(p_motivo), ''), 'Cadastro de variacao pela WEB-07.'),
          auth.uid()
        );
      end if;
    else
      v_saldo_anterior := v_variacao.estoque_atual;
      v_delta := v_estoque - v_saldo_anterior;

      update public.shopping_produto_variacoes
      set sku_variacao = v_sku_variacao,
          nome_variacao = v_nome,
          atributos = coalesce(atributos, '{}'::jsonb) || jsonb_build_object('ordem_grade', v_ordem),
          estoque_atual = v_estoque,
          ativo = true,
          atualizado_por = auth.uid()
      where id = v_variacao.id
      returning * into v_variacao;

      if v_delta <> 0 then
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
          case
            when v_saldo_anterior = 0 and v_delta > 0 then 'entrada_inicial'::public.shopping_tipo_movimento_estoque
            else 'ajuste_admin'::public.shopping_tipo_movimento_estoque
          end,
          v_delta,
          v_saldo_anterior,
          v_estoque,
          coalesce(nullif(btrim(p_motivo), ''), 'Ajuste de variacao pela WEB-07.'),
          auth.uid()
        );
      end if;
    end if;

    v_keep_ids := array_append(v_keep_ids, v_variacao.id);
    v_ordem := v_ordem + 1;
  end loop;

  for v_removida in
    select *
    from public.shopping_produto_variacoes spv
    where spv.produto_id = v_produto.id
      and spv.ativo
      and not (spv.id = any(v_keep_ids))
    for update
  loop
    update public.shopping_produto_variacoes
    set ativo = false,
        principal = false,
        estoque_atual = 0,
        atualizado_por = auth.uid()
    where id = v_removida.id;

    if v_removida.estoque_atual <> 0 then
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
        v_removida.id,
        v_produto.id,
        'ajuste_admin'::public.shopping_tipo_movimento_estoque,
        -v_removida.estoque_atual,
        v_removida.estoque_atual,
        0,
        coalesce(nullif(btrim(p_motivo), ''), 'Remocao logica de variacao pela WEB-07.'),
        auth.uid()
      );
    end if;
  end loop;

  update public.shopping_produto_variacoes spv
  set principal = true
  where spv.id = (
    select spv2.id
    from public.shopping_produto_variacoes spv2
    where spv2.produto_id = v_produto.id
      and spv2.ativo
    order by coalesce((spv2.atributos ->> 'ordem_grade')::integer, 0), spv2.criado_em, spv2.id
    limit 1
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
    'produto.variacoes.sincronizar',
    'shopping_produto_variacoes',
    v_produto.id,
    null,
    public.shopping_variacoes_json(v_produto.id, false),
    coalesce(nullif(btrim(p_motivo), ''), 'Sincronizacao de variacoes pela WEB-07.')
  );

  return public.shopping_variacoes_json(v_produto.id, false);
end;
$$;

drop function if exists public.shopping_admin_salvar_produto_com_variacoes(
  uuid, text, text, text, numeric, text, text, jsonb, jsonb, public.shopping_status_produto, jsonb
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
  p_variacoes jsonb default '[]'::jsonb
)
returns public.shopping_produtos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_perfil public.shopping_perfis := public.shopping_admin_assert_produtos_permitido();
  v_sku text;
  v_produto_existente public.shopping_produtos;
  v_produto public.shopping_produtos;
  v_variacoes jsonb := coalesce(p_variacoes, '[]'::jsonb);
begin
  if p_id is not null then
    select *
    into v_produto_existente
    from public.shopping_produtos sp
    where sp.id = p_id
    for update;

    if v_produto_existente.id is null then
      raise exception 'Produto nao encontrado para edicao.';
    end if;

    if v_perfil.papel = 'parceiro'::public.shopping_papel
      and v_produto_existente.criado_por is distinct from auth.uid() then
      raise exception 'Parceiro so pode editar produtos criados por ele.';
    end if;

    v_sku := v_produto_existente.sku;
  else
    v_sku := public.shopping_gerar_sku_produto(p_categoria, p_marca);
  end if;

  v_produto := public.shopping_admin_salvar_produto(
    p_id,
    v_sku,
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

  perform public.shopping_admin_sincronizar_variacoes_produto(
    v_produto.id,
    v_variacoes,
    'Cadastro administrativo de produto pela WEB-07.'
  );

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

drop function if exists public.shopping_catalogo_produtos_publicados_com_estoque();
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
  quantidade_estoque integer,
  variacoes jsonb
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
    se.quantidade_estoque,
    public.shopping_variacoes_json(sp.id, true) as variacoes
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

drop function if exists public.shopping_carrinho_atual();
create or replace function public.shopping_carrinho_atual()
returns table (
  carrinho_id uuid,
  item_id uuid,
  produto_id uuid,
  variacao_id uuid,
  variacao_nome text,
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
    spv.id as variacao_id,
    spv.nome_variacao as variacao_nome,
    sp.sku,
    sp.nome,
    sp.marca,
    sp.categoria,
    sci.preco_unitario,
    sci.quantidade,
    (sci.preco_unitario * sci.quantidade)::numeric as subtotal,
    coalesce(spv.estoque_atual, 0)::integer as estoque_disponivel,
    si.imagens,
    sci.atualizado_em
  from public.shopping_carrinho_itens sci
  join public.shopping_produtos sp on sp.id = sci.produto_id
  left join public.shopping_produto_variacoes spv on spv.id = sci.variacao_id
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
  where sci.carrinho_id = v_carrinho_id
  order by sci.atualizado_em desc, sci.criado_em desc;
end;
$$;

drop function if exists public.shopping_carrinho_adicionar_produto(uuid, integer);
drop function if exists public.shopping_carrinho_adicionar_produto(uuid, integer, uuid);
create or replace function public.shopping_carrinho_adicionar_produto(
  p_produto_id uuid,
  p_quantidade integer default 1,
  p_variacao_id uuid default null
)
returns public.shopping_carrinho_itens
language plpgsql
security definer
set search_path = public
as $$
declare
  v_carrinho_id uuid := public.shopping_carrinho_ativo_id();
  v_produto public.shopping_produtos;
  v_variacao public.shopping_produto_variacoes;
  v_item public.shopping_carrinho_itens;
  v_variacoes_ativas integer;
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

  select count(*)::integer
  into v_variacoes_ativas
  from public.shopping_produto_variacoes spv
  where spv.produto_id = v_produto.id
    and spv.ativo;

  if p_variacao_id is null and v_variacoes_ativas > 1 then
    raise exception 'Selecione uma variacao antes de adicionar ao carrinho.';
  end if;

  select *
  into v_variacao
  from public.shopping_produto_variacoes spv
  where spv.produto_id = v_produto.id
    and spv.ativo
    and (p_variacao_id is null or spv.id = p_variacao_id)
  order by spv.principal desc, spv.criado_em, spv.id
  limit 1
  for update;

  if v_variacao.id is null then
    raise exception 'Variacao indisponivel para compra.';
  end if;

  if v_variacao.estoque_atual <= 0 then
    raise exception 'Variacao sem estoque disponivel.';
  end if;

  select coalesce(sci.quantidade, 0)
  into v_quantidade_atual
  from public.shopping_carrinho_itens sci
  where sci.carrinho_id = v_carrinho_id
    and sci.produto_id = v_produto.id
    and sci.variacao_id = v_variacao.id
  for update;

  v_quantidade_final := coalesce(v_quantidade_atual, 0) + p_quantidade;

  if v_quantidade_final > v_variacao.estoque_atual then
    raise exception 'Quantidade solicitada maior que o estoque da variacao.';
  end if;

  insert into public.shopping_carrinho_itens (
    carrinho_id,
    produto_id,
    variacao_id,
    quantidade,
    preco_unitario
  )
  values (
    v_carrinho_id,
    v_produto.id,
    v_variacao.id,
    p_quantidade,
    v_produto.preco
  )
  on conflict (
    carrinho_id,
    produto_id,
    (coalesce(variacao_id, '00000000-0000-0000-0000-000000000000'::uuid))
  )
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
    'Produto adicionado ao carrinho com variacao pela WEB-07.'
  );

  return v_item;
end;
$$;

drop function if exists public.shopping_carrinho_definir_quantidade(uuid, integer);
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
  v_variacao public.shopping_produto_variacoes;
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

  select *
  into v_variacao
  from public.shopping_produto_variacoes spv
  where spv.id = v_item.variacao_id
    and spv.ativo
  for update;

  if v_variacao.id is null then
    raise exception 'Variacao indisponivel para atualizar o carrinho.';
  end if;

  if p_quantidade > v_variacao.estoque_atual then
    raise exception 'Quantidade solicitada maior que o estoque da variacao.';
  end if;

  update public.shopping_carrinho_itens
  set quantidade = p_quantidade
  where id = v_item.id
  returning * into v_item;

  return v_item;
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

  insert into public.shopping_pedidos (
    user_id,
    perfil_id,
    carrinho_id,
    status,
    pagamento_status,
    cliente_nome,
    cliente_email,
    subtotal,
    total
  )
  values (
    v_user_id,
    v_perfil.id,
    v_carrinho.id,
    'pendente_pagamento'::public.shopping_status_pedido,
    'pendente'::public.shopping_status_pagamento,
    v_perfil.nome_exibicao,
    v_perfil.email_normalizado,
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
    if v_item.status <> 'publicado'::public.shopping_status_produto then
      raise exception 'Produto indisponivel para gerar pedido.';
    end if;

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
      subtotal
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
      (v_item.preco_unitario * v_item.quantidade)::numeric(12, 2)
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
    'Pedido criado a partir do carrinho ativo pela WEB-07, preservando variacao.'
  );

  return v_pedido;
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
    and sp.user_id = auth.uid();
$$;

revoke all on function public.shopping_sku_codigo_categoria(text) from public, anon, authenticated;
revoke all on function public.shopping_normalizar_codigo(text) from public, anon, authenticated;
revoke all on function public.shopping_variacao_normalizar_valor(text) from public, anon, authenticated;
revoke all on function public.shopping_variacao_sku_segmento(text) from public, anon, authenticated;
revoke all on function public.shopping_gerar_sku_produto(text, text) from public, anon, authenticated;
revoke all on function public.shopping_variacoes_json(uuid, boolean) from public, anon, authenticated;
revoke all on function public.shopping_admin_sincronizar_variacoes_produto(uuid, jsonb, text) from public, anon, authenticated;
revoke all on function public.shopping_admin_salvar_produto_com_variacoes(uuid, text, text, text, numeric, text, text, jsonb, jsonb, public.shopping_status_produto, jsonb) from public, anon, authenticated;
revoke all on function public.shopping_admin_listar_produtos_com_estoque() from public, anon, authenticated;
revoke all on function public.shopping_catalogo_produtos_publicados_com_estoque() from public, anon, authenticated;
revoke all on function public.shopping_carrinho_atual() from public, anon, authenticated;
revoke all on function public.shopping_carrinho_adicionar_produto(uuid, integer, uuid) from public, anon, authenticated;
revoke all on function public.shopping_carrinho_definir_quantidade(uuid, integer) from public, anon, authenticated;
revoke all on function public.shopping_pedido_finalizar_carrinho() from public, anon, authenticated;
revoke all on function public.shopping_pedidos_cliente_listar() from public, anon, authenticated;
revoke all on function public.shopping_admin_listar_pedidos() from public, anon, authenticated;
revoke all on function public.shopping_pagamento_checkout_context(uuid) from public, anon, authenticated;

grant execute on function public.shopping_admin_salvar_produto_com_variacoes(uuid, text, text, text, numeric, text, text, jsonb, jsonb, public.shopping_status_produto, jsonb) to authenticated;
grant execute on function public.shopping_admin_listar_produtos_com_estoque() to authenticated;
grant execute on function public.shopping_catalogo_produtos_publicados_com_estoque() to anon, authenticated;
grant execute on function public.shopping_carrinho_atual() to authenticated;
grant execute on function public.shopping_carrinho_adicionar_produto(uuid, integer, uuid) to authenticated;
grant execute on function public.shopping_carrinho_definir_quantidade(uuid, integer) to authenticated;
grant execute on function public.shopping_pedido_finalizar_carrinho() to authenticated;
grant execute on function public.shopping_pedidos_cliente_listar() to authenticated;
grant execute on function public.shopping_admin_listar_pedidos() to authenticated;
grant execute on function public.shopping_pagamento_checkout_context(uuid) to authenticated;

comment on function public.shopping_gerar_sku_produto(text, text) is
  'Gera SKU atomico por prefixo CATEGORIA-MARCA usando advisory lock transacional e maior sequencial existente.';

comment on function public.shopping_admin_salvar_produto_com_variacoes(uuid, text, text, text, numeric, text, text, jsonb, jsonb, public.shopping_status_produto, jsonb) is
  'Cria produto com SKU automatico ou edita preservando SKU, sincronizando variacoes flexiveis e estoque.';

comment on index public.idx_shopping_carrinho_itens_unique_produto_variacao is
  'Garante que o carrinho trate produto + variacao como chave logica do item.';

notify pgrst, 'reload schema';
