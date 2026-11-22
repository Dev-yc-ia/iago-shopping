BEGIN;
SET LOCAL lock_timeout = '8s';
LOCK TABLE operacao.tentativas IN SHARE MODE;

DO $$
BEGIN
    IF EXISTS (SELECT FROM operacao.tentativas WHERE estado IN ('chamada', 'aberta')) THEN
        RAISE EXCEPTION 'Há uma volta em pista. Conclua ou cancele antes da migração.';
    END IF;
END;
$$;

ALTER TABLE cadastro.inscricoes
    DROP CONSTRAINT inscricoes_evento_id_skatista_id_key,
    DROP CONSTRAINT inscricoes_evento_id_chave_origem_key,
    ADD UNIQUE (evento_id, skatista_id, categoria_base_id),
    ADD UNIQUE (evento_id, chave_origem, categoria_base_id);

-- A ordem provisória evita colisões com a unicidade imediata.
CREATE FUNCTION cadastro.provisionar_categorias(p_evento uuid) RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
    catalogo constant text[] := ARRAY['1ª','2ª','3ª','4ª'];
    deslocamento integer;
BEGIN
    IF EXISTS (
        SELECT FROM cadastro.categorias
        WHERE evento_id = p_evento AND codigo <> ALL(catalogo)
    ) THEN
        RAISE EXCEPTION 'Catálogo fora do padrão; revise as categorias do evento.';
    END IF;
    IF EXISTS (
        SELECT FROM cadastro.categorias
        WHERE evento_id = p_evento AND ordem <> array_position(catalogo, codigo)
    ) THEN
        SELECT greatest(coalesce(max(ordem), 0), 4) INTO deslocamento
        FROM cadastro.categorias WHERE evento_id = p_evento;
        UPDATE cadastro.categorias SET ordem = deslocamento + array_position(catalogo, codigo)
        WHERE evento_id = p_evento;
        UPDATE cadastro.categorias SET ordem = array_position(catalogo, codigo)
        WHERE evento_id = p_evento;
    END IF;
    INSERT INTO cadastro.categorias(evento_id, codigo, ordem)
    SELECT p_evento, codigo, ordem FROM unnest(catalogo) WITH ORDINALITY AS c(codigo, ordem)
    ON CONFLICT (evento_id, codigo) DO NOTHING;
END;
$$;

SELECT cadastro.provisionar_categorias(id) FROM cadastro.eventos;

-- Usada somente depois de validar a sessão Master e obter a trava do importador.
CREATE FUNCTION cadastro.incluir_inscricao(
    p_evento uuid, p_chave text, p_nome text, p_escola text, p_nascimento date,
    p_sexo text, p_categoria text
) RETURNS TABLE (pessoa uuid, incluido boolean, pessoa_nova boolean)
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
    categoria uuid;
    atual record;
BEGIN
    SELECT id INTO categoria FROM cadastro.categorias
    WHERE evento_id = p_evento AND codigo = p_categoria;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = 'IA422', MESSAGE = 'Categoria-base indisponível no evento.';
    END IF;
    SELECT s.id, s.escola, s.sexo_confirmado INTO atual
    FROM cadastro.inscricoes i JOIN cadastro.skatistas s ON s.id = i.skatista_id
    WHERE i.evento_id = p_evento AND i.chave_origem = p_chave::char(64)
    LIMIT 1;
    pessoa_nova := NOT FOUND;
    IF NOT pessoa_nova THEN
        IF (atual.escola, atual.sexo_confirmado) IS DISTINCT FROM (p_escola, p_sexo) THEN
            RAISE EXCEPTION USING ERRCODE = 'IA409', MESSAGE = 'Identidade já cadastrada com dados divergentes.';
        END IF;
        pessoa := atual.id;
    ELSE
        INSERT INTO cadastro.skatistas(nome, escola, data_nascimento, sexo_confirmado)
        VALUES (p_nome, p_escola, p_nascimento, p_sexo) RETURNING id INTO pessoa;
    END IF;
    INSERT INTO cadastro.inscricoes(evento_id, skatista_id, chave_origem, categoria_base_id, numero_provisorio)
    SELECT p_evento, pessoa, p_chave, categoria, coalesce(max(numero_provisorio), 0) + 1
    FROM cadastro.inscricoes WHERE evento_id = p_evento
    ON CONFLICT (evento_id, skatista_id, categoria_base_id) DO NOTHING;
    incluido := FOUND;
    RETURN NEXT;
END;
$$;

-- Única operação com elevação de privilégio. O runtime não recebe DELETE geral.
CREATE FUNCTION cadastro.retirar_inscricao(p_evento uuid, p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
    PERFORM 1 FROM operacao.controle_evento WHERE evento_id = p_evento FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = 'IA409', MESSAGE = 'Evento sem controle de votação.';
    END IF;
    IF EXISTS (SELECT FROM operacao.tentativas WHERE evento_id = p_evento AND inscricao_id = p_id) THEN
        RAISE EXCEPTION USING ERRCODE = 'IA409', MESSAGE = 'A categoria tem histórico e não pode ser retirada.';
    END IF;
    DELETE FROM cadastro.inscricoes WHERE evento_id = p_evento AND id = p_id;
END;
$$;

-- O chamador já bloqueou controle_evento, sessão e alocação, nessa ordem.
CREATE FUNCTION cadastro.editar_inscricoes(
    p_evento uuid, p_id uuid, p_chave text, p_nome text, p_escola text,
    p_nascimento date, p_sexo text, p_categorias text[], p_legado boolean, p_foto boolean
) RETURNS uuid
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
    atual record;
    inscricao record;
    selecionadas uuid[];
    codigo text;
    alterou_identidade boolean;
    alterou_pessoa boolean;
BEGIN
    SELECT s.id, s.nome, s.escola, s.data_nascimento, s.sexo_confirmado, i.categoria_base_id
    INTO atual
    FROM cadastro.inscricoes i JOIN cadastro.skatistas s ON s.id = i.skatista_id
    WHERE i.evento_id = p_evento AND i.id = p_id FOR UPDATE OF s;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = 'IA404', MESSAGE = 'Inscrição não encontrada.';
    END IF;
    SELECT array_agg(id) INTO selecionadas FROM cadastro.categorias
    WHERE evento_id = p_evento AND cadastro.categorias.codigo = ANY(p_categorias);
    IF coalesce(cardinality(selecionadas), 0) NOT BETWEEN 1 AND 4
       OR cardinality(selecionadas) <> cardinality(p_categorias) THEN
        RAISE EXCEPTION USING ERRCODE = 'IA422', MESSAGE = 'Selecione de uma a quatro categorias válidas e distintas.';
    END IF;
    IF EXISTS (
        SELECT FROM operacao.tentativas t JOIN cadastro.inscricoes i
          ON (i.evento_id, i.id) = (t.evento_id, t.inscricao_id)
        WHERE i.evento_id = p_evento AND i.skatista_id = atual.id AND t.estado IN ('chamada','aberta')
    ) THEN
        RAISE EXCEPTION USING ERRCODE = 'IA409', MESSAGE = 'Conclua ou cancele a volta em pista antes de editar.';
    END IF;
    alterou_identidade := (atual.nome, atual.data_nascimento) IS DISTINCT FROM (p_nome, p_nascimento);
    alterou_pessoa := alterou_identidade OR
        (atual.escola, atual.sexo_confirmado) IS DISTINCT FROM (p_escola, p_sexo);
    IF (alterou_pessoa OR p_foto) AND EXISTS (
        SELECT FROM cadastro.inscricoes WHERE skatista_id = atual.id AND evento_id <> p_evento
    ) THEN
        RAISE EXCEPTION USING ERRCODE = 'IA409', MESSAGE = 'Este skatista tem inscrições em outro evento.';
    END IF;
    IF alterou_identidade AND EXISTS (
        SELECT FROM cadastro.inscricoes WHERE evento_id = p_evento
        AND chave_origem = p_chave::char(64) AND skatista_id <> atual.id
    ) THEN
        RAISE EXCEPTION USING ERRCODE = 'IA409', MESSAGE = 'Já existe cadastro com esse nome e nascimento.';
    END IF;
    IF alterou_pessoa THEN
        UPDATE cadastro.skatistas SET nome = p_nome, escola = p_escola,
               data_nascimento = p_nascimento, sexo_confirmado = p_sexo WHERE id = atual.id;
    END IF;
    IF alterou_identidade THEN
        UPDATE cadastro.inscricoes SET chave_origem = p_chave
        WHERE evento_id = p_evento AND skatista_id = atual.id;
    END IF;
    IF p_legado THEN
        IF selecionadas[1] <> atual.categoria_base_id THEN
            IF EXISTS (SELECT FROM operacao.tentativas WHERE evento_id = p_evento AND inscricao_id = p_id) THEN
                RAISE EXCEPTION USING ERRCODE = 'IA409', MESSAGE = 'A categoria tem histórico e não pode ser alterada.';
            END IF;
            UPDATE cadastro.inscricoes SET categoria_base_id = selecionadas[1]
            WHERE evento_id = p_evento AND id = p_id;
        END IF;
    ELSE
        -- Inclua primeiro para que a numeração nova considere todas as inscrições atuais.
        FOREACH codigo IN ARRAY p_categorias LOOP
            PERFORM cadastro.incluir_inscricao(p_evento, p_chave, p_nome, p_escola, p_nascimento, p_sexo, codigo);
        END LOOP;
        FOR inscricao IN
            SELECT id FROM cadastro.inscricoes WHERE evento_id = p_evento
            AND skatista_id = atual.id AND categoria_base_id <> ALL(selecionadas)
        LOOP
            PERFORM cadastro.retirar_inscricao(p_evento, inscricao.id);
        END LOOP;
    END IF;
    RETURN atual.id;
END;
$$;

REVOKE ALL ON FUNCTION cadastro.provisionar_categorias(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION cadastro.incluir_inscricao(uuid,text,text,text,date,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION cadastro.editar_inscricoes(uuid,uuid,text,text,text,date,text,text[],boolean,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION cadastro.retirar_inscricao(uuid,uuid) FROM PUBLIC;

DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'iago_importador') THEN
        GRANT EXECUTE ON FUNCTION cadastro.provisionar_categorias(uuid) TO iago_importador;
    END IF;
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'iago_runtime') THEN
        GRANT EXECUTE ON FUNCTION cadastro.incluir_inscricao(uuid,text,text,text,date,text,text) TO iago_runtime;
        GRANT EXECUTE ON FUNCTION cadastro.editar_inscricoes(uuid,uuid,text,text,text,date,text,text[],boolean,boolean) TO iago_runtime;
        GRANT EXECUTE ON FUNCTION cadastro.retirar_inscricao(uuid,uuid) TO iago_runtime;
    END IF;
END;
$$;
COMMIT;
