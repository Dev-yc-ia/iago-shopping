-- Trava operacional separada: runtime continua sem UPDATE no cadastro.
CREATE TABLE operacao.controle_evento (
    evento_id uuid PRIMARY KEY REFERENCES cadastro.eventos(id)
);
REVOKE ALL ON operacao.controle_evento FROM PUBLIC;
