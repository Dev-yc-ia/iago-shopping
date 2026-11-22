"""Consultas do evento local. Cada endpoint seleciona apenas seu contrato."""

from backend.config.settings import Settings
from backend.db import read_connection


def ranking(settings: Settings) -> dict:
    """Catálogo compatível, acrescido somente de pista e resultados publicados."""
    from backend.services.votacao import ranking_publico

    return ranking_publico(settings)


def credenciamento(settings: Settings) -> dict:
    """Contrato privado do cadastro para o Master em loopback."""
    with read_connection(settings) as connection:
        rows = connection.execute(
            """
            SELECT i.id, i.skatista_id, i.numero_provisorio, s.nome, s.escola,
                   s.data_nascimento, s.ano_nascimento, s.sexo_confirmado,
                   base.codigo AS categoria_base, f.versao AS avatar_versao
            FROM cadastro.inscricoes AS i
            JOIN cadastro.eventos AS e ON e.id = i.evento_id
            JOIN cadastro.skatistas AS s ON s.id = i.skatista_id
            LEFT JOIN cadastro.fotos_skatistas AS f ON f.skatista_id=s.id
            JOIN cadastro.categorias AS base ON base.id = i.categoria_base_id
            WHERE e.codigo = %s
            ORDER BY i.numero_provisorio
            """,
            (settings.evento_codigo,),
        ).fetchall()
        categorias = connection.execute(
            """SELECT c.codigo FROM cadastro.categorias c JOIN cadastro.eventos e
            ON e.id=c.evento_id WHERE e.codigo=%s ORDER BY c.ordem""",
            (settings.evento_codigo,),
        ).fetchall()
    return {
        "categorias": [row["codigo"] for row in categorias],
        "inscricoes": [
            {
                "id": str(row["id"]),
                "skatista_id": str(row["skatista_id"]),
                "numero_provisorio": row["numero_provisorio"],
                "nome": row["nome"],
                "escola": row["escola"],
                "data_nascimento": row["data_nascimento"].isoformat(),
                "ano_nascimento": row["ano_nascimento"],
                "sexo_confirmado": row["sexo_confirmado"],
                "categoria_base": row["categoria_base"],
                "avatar_versao": row["avatar_versao"],
            }
            for row in rows
        ],
    }
