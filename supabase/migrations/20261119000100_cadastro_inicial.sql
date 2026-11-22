-- Estrutura portátil entre PostgreSQL 17 puro e Supabase local/remoto.
-- Nenhum dado pessoal nem senha faz parte da migração.
CREATE SCHEMA cadastro;
REVOKE ALL ON SCHEMA cadastro FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA cadastro REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA cadastro REVOKE ALL ON SEQUENCES FROM PUBLIC;

CREATE TABLE cadastro.eventos (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    codigo text NOT NULL UNIQUE CHECK (btrim(codigo) <> '')
);

CREATE TABLE cadastro.categorias (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    evento_id uuid NOT NULL REFERENCES cadastro.eventos(id),
    codigo text NOT NULL CHECK (btrim(codigo) <> ''),
    ordem integer NOT NULL CHECK (ordem > 0),
    UNIQUE (evento_id, codigo),
    UNIQUE (evento_id, ordem),
    UNIQUE (evento_id, id)
);

CREATE TABLE cadastro.skatistas (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nome text NOT NULL CHECK (btrim(nome) <> ''),
    escola text NOT NULL CHECK (btrim(escola) <> ''),
    data_nascimento date NOT NULL CHECK (data_nascimento >= DATE '1900-01-01'),
    ano_nascimento integer GENERATED ALWAYS AS (
        EXTRACT(YEAR FROM data_nascimento)::integer
    ) STORED,
    sexo_confirmado text NOT NULL CHECK (
        sexo_confirmado IN ('Feminino', 'Masculino')
    )
);

CREATE TABLE cadastro.inscricoes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    evento_id uuid NOT NULL REFERENCES cadastro.eventos(id),
    skatista_id uuid NOT NULL REFERENCES cadastro.skatistas(id),
    chave_origem char(64) NOT NULL,
    categoria_base_id uuid NOT NULL,
    categoria_confirmada_id uuid,
    numero_provisorio integer NOT NULL CHECK (numero_provisorio > 0),
    UNIQUE (evento_id, chave_origem),
    UNIQUE (evento_id, skatista_id),
    UNIQUE (evento_id, numero_provisorio),
    FOREIGN KEY (evento_id, categoria_base_id)
        REFERENCES cadastro.categorias(evento_id, id),
    FOREIGN KEY (evento_id, categoria_confirmada_id)
        REFERENCES cadastro.categorias(evento_id, id)
);

REVOKE ALL ON ALL TABLES IN SCHEMA cadastro FROM PUBLIC;
-- As roles existem no Supabase, mas são opcionais no PostgreSQL puro.
DO $$
DECLARE
    role_name text;
BEGIN
    FOREACH role_name IN ARRAY ARRAY['anon', 'authenticated'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
            EXECUTE format('REVOKE ALL ON SCHEMA cadastro FROM %I', role_name);
            EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA cadastro FROM %I', role_name);
        END IF;
    END LOOP;
END;
$$;
