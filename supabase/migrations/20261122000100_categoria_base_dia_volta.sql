ALTER TABLE cadastro.inscricoes DROP COLUMN categoria_confirmada_id;

ALTER TABLE operacao.tentativas ADD COLUMN dia_volta date;
UPDATE operacao.tentativas t
SET dia_volta = primeiro.dia
FROM (
    SELECT evento_id, tentativa_id,
           (min(horario) AT TIME ZONE 'America/Sao_Paulo')::date AS dia
    FROM operacao.votos
    GROUP BY evento_id, tentativa_id
) primeiro
WHERE t.evento_id = primeiro.evento_id AND t.id = primeiro.tentativa_id;

DROP INDEX operacao.um_resultado_por_volta;
CREATE UNIQUE INDEX um_resultado_por_volta_dia
    ON operacao.tentativas(evento_id, dia_volta, inscricao_id, volta)
    WHERE estado = 'concluida' AND dia_volta IS NOT NULL;
CREATE INDEX tentativas_dias ON operacao.tentativas(evento_id, dia_volta)
    WHERE dia_volta IS NOT NULL;
CREATE INDEX votos_dia ON operacao.votos(
    evento_id, ((horario AT TIME ZONE 'America/Sao_Paulo')::date)
);

CREATE VIEW operacao.notas_por_dia AS
SELECT v.id, v.evento_id, v.tentativa_id, v.juiz_id, i.skatista_id, t.volta,
       v.nota, v.horario, (v.horario AT TIME ZONE 'America/Sao_Paulo')::date AS dia_voto,
       t.dia_volta, t.estado
FROM operacao.votos v
JOIN operacao.tentativas t ON (t.evento_id,t.id)=(v.evento_id,v.tentativa_id)
JOIN cadastro.inscricoes i ON (i.evento_id,i.id)=(t.evento_id,t.inscricao_id);
REVOKE ALL ON operacao.notas_por_dia FROM PUBLIC;
