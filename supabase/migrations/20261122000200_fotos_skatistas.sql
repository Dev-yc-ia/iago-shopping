BEGIN;
CREATE TABLE cadastro.fotos_skatistas (
    skatista_id uuid PRIMARY KEY REFERENCES cadastro.skatistas(id),
    versao uuid NOT NULL DEFAULT gen_random_uuid(),
    png bytea NOT NULL CHECK (octet_length(png) BETWEEN 1 AND 70000)
);
REVOKE ALL ON cadastro.fotos_skatistas FROM PUBLIC;
DO $$
DECLARE
    papel text;
BEGIN
    FOREACH papel IN ARRAY ARRAY['anon', 'authenticated', 'iago_importador'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
            EXECUTE format('REVOKE ALL ON cadastro.fotos_skatistas FROM %I', papel);
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'iago_runtime') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON cadastro.fotos_skatistas TO iago_runtime;
        GRANT UPDATE (nome, escola, data_nascimento, sexo_confirmado) ON cadastro.skatistas TO iago_runtime;
        GRANT UPDATE (categoria_base_id, chave_origem) ON cadastro.inscricoes TO iago_runtime;
    END IF;
END
$$;
COMMIT;
