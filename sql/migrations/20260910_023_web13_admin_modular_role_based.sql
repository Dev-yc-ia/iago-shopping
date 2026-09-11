-- IAGO Shopping - WEB-13
-- Admin modular por papel: parceiro cadastra produto próprio sem controlar repasse/publicação.

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
  v_is_parceiro boolean := v_perfil.papel = 'parceiro'::public.shopping_papel;
  v_parceiro_user_id uuid := p_parceiro_user_id;
  v_valor_repasse_parceiro numeric := p_valor_repasse_parceiro;
  v_status public.shopping_status_produto := p_status;
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

    if v_is_parceiro and v_produto.parceiro_user_id is distinct from auth.uid() then
      raise exception 'Parceiro so pode editar produtos sob sua responsabilidade.';
    end if;

    if v_is_master then
      v_parceiro_user_id := p_parceiro_user_id;
      v_valor_repasse_parceiro := p_valor_repasse_parceiro;
      v_status := p_status;
    else
      v_parceiro_user_id := v_produto.parceiro_user_id;
      v_valor_repasse_parceiro := v_produto.valor_repasse_parceiro;
      v_status := case
        when p_status = 'publicado'::public.shopping_status_produto
          and v_produto.status <> 'publicado'::public.shopping_status_produto
          then 'rascunho'::public.shopping_status_produto
        else p_status
      end;
    end if;

    v_sku := v_produto.sku;
  else
    if v_is_master then
      v_parceiro_user_id := p_parceiro_user_id;
      v_valor_repasse_parceiro := p_valor_repasse_parceiro;
      v_status := p_status;
    elsif v_is_parceiro then
      v_parceiro_user_id := auth.uid();
      v_valor_repasse_parceiro := null;
      v_status := 'rascunho'::public.shopping_status_produto;
    else
      v_parceiro_user_id := null;
      v_valor_repasse_parceiro := null;
      v_status := case
        when p_status = 'publicado'::public.shopping_status_produto
          then 'rascunho'::public.shopping_status_produto
        else p_status
      end;
    end if;

    v_sku := public.shopping_gerar_sku_produto(p_categoria, p_marca);
  end if;

  if v_parceiro_user_id is not null then
    perform public.shopping_parceiro_ativo_assert(v_parceiro_user_id);
  end if;

  if v_status = 'publicado'::public.shopping_status_produto
    and (v_parceiro_user_id is null or v_valor_repasse_parceiro is null) then
    raise exception 'Produto publicado precisa de parceiro ativo e repasse configurado.';
  end if;

  if p_id is not null then
    update public.shopping_produtos
    set nome = btrim(p_nome),
        marca = btrim(p_marca),
        categoria = btrim(p_categoria),
        preco = p_preco,
        destaque = nullif(btrim(p_destaque), ''),
        descricao = nullif(btrim(p_descricao), ''),
        atributos = p_atributos,
        status = v_status,
        parceiro_user_id = v_parceiro_user_id,
        valor_repasse_parceiro = v_valor_repasse_parceiro,
        atualizado_por = auth.uid()
    where id = p_id
    returning * into v_produto;
  else
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
      v_status,
      v_parceiro_user_id,
      v_valor_repasse_parceiro,
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
    'Cadastro de produto pelo Admin modular WEB-13.'
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
    'Cadastro de produto pelo Admin modular WEB-13.'
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
      'Parceiro responsavel definido pelo Admin modular WEB-13.'
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
      'Valor de repasse ao parceiro definido pelo Admin modular WEB-13.'
    );
  end if;

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
    and (v_antes ->> 'parceiro_user_id')::uuid is distinct from auth.uid() then
    raise exception 'Parceiro so pode excluir produtos sob sua responsabilidade.';
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

revoke all on function public.shopping_admin_salvar_produto_com_variacoes(
  uuid, text, text, text, numeric, text, text, jsonb, jsonb, public.shopping_status_produto, jsonb, uuid, numeric
) from public, anon, authenticated;
revoke all on function public.shopping_admin_excluir_produto(uuid, text) from public, anon, authenticated;

grant execute on function public.shopping_admin_salvar_produto_com_variacoes(
  uuid, text, text, text, numeric, text, text, jsonb, jsonb, public.shopping_status_produto, jsonb, uuid, numeric
) to authenticated;
grant execute on function public.shopping_admin_excluir_produto(uuid, text) to authenticated;

comment on function public.shopping_admin_salvar_produto_com_variacoes(
  uuid, text, text, text, numeric, text, text, jsonb, jsonb, public.shopping_status_produto, jsonb, uuid, numeric
) is
  'WEB-13: Master controla parceiro/repasse/publicacao; parceiro cria e edita somente produtos sob sua responsabilidade, em rascunho quando nao houver revisao comercial.';

notify pgrst, 'reload schema';
