-- Estado de exibição independente da tentativa ativa; sem alteração de votos.
ALTER TABLE operacao.controle_evento
    ADD COLUMN filtro_categoria_id uuid,
    ADD COLUMN filtro_sexo text,
    ADD COLUMN filtro_revisao bigint NOT NULL DEFAULT 0 CHECK (filtro_revisao >= 0),
    ADD CONSTRAINT filtro_categoria_evento_fk FOREIGN KEY (evento_id,filtro_categoria_id)
        REFERENCES cadastro.categorias(evento_id,id),
    ADD CONSTRAINT filtro_completo CHECK (
        (filtro_categoria_id IS NULL AND filtro_sexo IS NULL) OR
        (filtro_categoria_id IS NOT NULL AND filtro_sexo IS NOT NULL
         AND filtro_sexo IN ('Masculino','Feminino')));
-- A combinação existente é validada na API, sob a trava do evento.
-- As ACLs existentes de controle_evento já permitem leitura e atualização pelo runtime.
