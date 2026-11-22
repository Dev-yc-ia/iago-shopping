-- Incremental: não apaga nem altera valores do cadastro importado.
CREATE SCHEMA operacao;
REVOKE ALL ON SCHEMA operacao FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA operacao REVOKE ALL ON TABLES FROM PUBLIC;
ALTER TABLE cadastro.inscricoes ADD CONSTRAINT inscricao_evento_id UNIQUE (evento_id, id);

CREATE TABLE operacao.usuarios (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nome text NOT NULL CHECK (length(btrim(nome)) BETWEEN 1 AND 120),
    login text NOT NULL UNIQUE CHECK (login ~ '^[a-z0-9_.-]{3,60}$'),
    senha_hash text NOT NULL,
    perfil text NOT NULL CHECK (perfil IN ('master', 'juiz')),
    ativo boolean NOT NULL DEFAULT true,
    trocar_senha boolean NOT NULL DEFAULT true,
    criado_em timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE operacao.sessoes (
    token_hash char(64) PRIMARY KEY,
    usuario_id uuid NOT NULL REFERENCES operacao.usuarios(id),
    csrf_token text NOT NULL,
    criado_em timestamptz NOT NULL DEFAULT now(),
    expira_em timestamptz NOT NULL
);
CREATE INDEX sessoes_usuario ON operacao.sessoes(usuario_id);
CREATE TABLE operacao.login_falhas (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    chave char(64) NOT NULL,
    horario timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX login_falhas_chave ON operacao.login_falhas(chave, horario);
CREATE TABLE operacao.tentativas (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    evento_id uuid NOT NULL REFERENCES cadastro.eventos(id),
    inscricao_id uuid NOT NULL,
    volta smallint NOT NULL CHECK (volta IN (1,2)),
    estado text NOT NULL CHECK (estado IN ('chamada','aberta','concluida','cancelada')),
    criada_por uuid NOT NULL REFERENCES operacao.usuarios(id),
    criada_em timestamptz NOT NULL DEFAULT now(),
    aberta_em timestamptz,
    encerrada_em timestamptz,
    media numeric(5,2) CHECK (media BETWEEN 0 AND 100),
    motivo_cancelamento text,
    UNIQUE (evento_id, id),
    FOREIGN KEY (evento_id, inscricao_id) REFERENCES cadastro.inscricoes(evento_id, id),
    CHECK ((estado = 'concluida') = (media IS NOT NULL)),
    CHECK (estado NOT IN ('concluida','cancelada') OR encerrada_em IS NOT NULL),
    CHECK (estado NOT IN ('aberta','concluida') OR aberta_em IS NOT NULL),
    CHECK (estado <> 'cancelada' OR length(btrim(motivo_cancelamento)) BETWEEN 3 AND 500)
);
CREATE UNIQUE INDEX uma_pista_por_evento ON operacao.tentativas(evento_id)
    WHERE estado IN ('chamada','aberta');
CREATE UNIQUE INDEX um_resultado_por_volta ON operacao.tentativas(evento_id, inscricao_id, volta)
    WHERE estado = 'concluida';
CREATE TABLE operacao.bancas (
    evento_id uuid NOT NULL,
    tentativa_id uuid NOT NULL,
    juiz_id uuid NOT NULL REFERENCES operacao.usuarios(id),
    PRIMARY KEY (evento_id, tentativa_id, juiz_id),
    FOREIGN KEY (evento_id, tentativa_id) REFERENCES operacao.tentativas(evento_id,id)
);
CREATE TABLE operacao.votos (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    evento_id uuid NOT NULL,
    tentativa_id uuid NOT NULL,
    juiz_id uuid NOT NULL,
    nota numeric(5,2) NOT NULL CHECK (nota BETWEEN 0 AND 100),
    horario timestamptz NOT NULL DEFAULT now(),
    UNIQUE (evento_id, tentativa_id, juiz_id),
    FOREIGN KEY (evento_id, tentativa_id, juiz_id)
        REFERENCES operacao.bancas(evento_id, tentativa_id, juiz_id)
);
REVOKE ALL ON ALL TABLES IN SCHEMA operacao FROM PUBLIC;
DO $$
DECLARE role_name text;
BEGIN
    FOREACH role_name IN ARRAY ARRAY['anon','authenticated'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname=role_name) THEN
            EXECUTE format('REVOKE ALL ON SCHEMA operacao FROM %I',role_name);
            EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA operacao FROM %I',role_name);
        END IF;
    END LOOP;
END;
$$;
