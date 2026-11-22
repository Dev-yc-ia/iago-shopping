"""Importação privada e atômica. Saída contém apenas contagens, nunca registros."""

import argparse
import csv
import hashlib
import json
import re
import unicodedata
from collections import Counter
from dataclasses import dataclass
from datetime import date
from pathlib import Path

import psycopg

from backend.config.paths import PRIVATE_CSV
from backend.config.settings import get_settings, import_database_url

CABECALHO = [
    "atleta",
    "escola",
    "data_nascimento",
    "ano_nascimento",
    "sexo_confirmado",
    "categoria_base_idade",
]
DISTRIBUICAO_LEGADA = {"2ª": 3, "3ª": 3, "4ª": 6}


@dataclass(frozen=True, repr=False)
class Registro:
    nome: str
    escola: str
    nascimento: date
    sexo: str
    categoria: str
    chave: str


def chave_origem(evento: str, nome: str, nascimento: date) -> str:
    """Casefold/NFKC/espaços identificam a origem; a grafia salva não é normalizada."""
    normalizado = " ".join(unicodedata.normalize("NFKC", nome).casefold().split())
    payload = json.dumps(
        [evento, normalizado, nascimento.isoformat()], ensure_ascii=False
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def validar_csv(caminho: Path, evento: str) -> list[Registro]:
    """Valida todo o lote antes do primeiro INSERT; erros não reproduzem campos."""
    registros = []
    try:
        with caminho.open(encoding="utf-8-sig", newline="") as arquivo:
            leitor = csv.reader(arquivo, delimiter=";", strict=True)
            if next(leitor, None) != CABECALHO:
                raise ValueError(
                    "Cabeçalho inválido: esperadas as seis colunas do contrato."
                )
            for linha, campos in enumerate(leitor, start=2):
                if len(campos) != 6 or any(not campo.strip() for campo in campos):
                    raise ValueError(
                        f"Linha {linha}: seis campos preenchidos são obrigatórios."
                    )
                nome, escola, data_texto, ano, sexo, categoria = campos
                try:
                    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", data_texto):
                        raise ValueError
                    nascimento = date.fromisoformat(data_texto)
                    if nascimento < date(1900, 1, 1) or nascimento > date.today():
                        raise ValueError
                    if not re.fullmatch(r"\d{4}", ano) or int(ano) != nascimento.year:
                        raise ValueError
                except ValueError:
                    raise ValueError(
                        f"Linha {linha}: data ISO ou ano incoerente."
                    ) from None
                if categoria not in DISTRIBUICAO_LEGADA or sexo not in {
                    "Feminino",
                    "Masculino",
                }:
                    raise ValueError(
                        f"Linha {linha}: categoria ou sexo confirmado inválido."
                    )
                registros.append(
                    Registro(
                        nome,
                        escola,
                        nascimento,
                        sexo,
                        categoria,
                        chave_origem(evento, nome, nascimento),
                    )
                )
    except (UnicodeError, csv.Error):
        raise ValueError(
            "CSV inválido: use UTF-8 e delimitador ponto e vírgula."
        ) from None
    if (
        len(registros) != 12
        or Counter(r.categoria for r in registros) != DISTRIBUICAO_LEGADA
    ):
        raise ValueError("Esperados 12 registros e distribuição de categorias 3/3/6.")
    if len({r.chave for r in registros}) != len(registros):
        raise ValueError("Identidade duplicada no CSV; nenhuma alteração foi aplicada.")
    return registros


def gravar_registro(connection, evento_id, categorias, registro, existente, numero):
    """Reexecução atualiza atributos, preservando ID e número provisório."""
    if existente:
        skatista_id = existente["skatista_id"]
        if connection.execute(
            """SELECT 1 FROM cadastro.inscricoes
            WHERE skatista_id=%s AND evento_id<>%s LIMIT 1""",
            (skatista_id, evento_id),
        ).fetchone():
            raise ValueError("Skatista com inscrições em outro evento.")
        connection.execute(
            """
            UPDATE cadastro.skatistas
            SET nome = %s, escola = %s, data_nascimento = %s, sexo_confirmado = %s
            WHERE id = %s
            """,
            (
                registro.nome,
                registro.escola,
                registro.nascimento,
                registro.sexo,
                skatista_id,
            ),
        )
    else:
        skatista_id = connection.execute(
            """
            INSERT INTO cadastro.skatistas (nome, escola, data_nascimento, sexo_confirmado)
            VALUES (%s, %s, %s, %s) RETURNING id
            """,
            (registro.nome, registro.escola, registro.nascimento, registro.sexo),
        ).fetchone()[0]
    connection.execute(
        """
        INSERT INTO cadastro.inscricoes (
            evento_id, skatista_id, chave_origem, categoria_base_id, numero_provisorio
        ) VALUES (%s, %s, %s, %s, %s)
        ON CONFLICT (evento_id, skatista_id, categoria_base_id) DO NOTHING
        """,
        (
            evento_id,
            skatista_id,
            registro.chave,
            categorias[registro.categoria],
            numero,
        ),
    )


def importar(caminho: Path, database_url: str, evento: str) -> dict:
    """Uma transação e trava por evento: falha em qualquer registro desfaz todo o lote."""
    registros = validar_csv(caminho, evento)
    with psycopg.connect(database_url, connect_timeout=5) as connection:
        connection.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", (evento,))
        evento_id = connection.execute(
            """
            INSERT INTO cadastro.eventos (codigo) VALUES (%s)
            ON CONFLICT (codigo) DO UPDATE SET codigo = EXCLUDED.codigo
            RETURNING id
            """,
            (evento,),
        ).fetchone()[0]
        connection.execute("SELECT cadastro.provisionar_categorias(%s)", (evento_id,))
        categorias = dict(
            connection.execute(
                "SELECT codigo, id FROM cadastro.categorias WHERE evento_id=%s",
                (evento_id,),
            ).fetchall()
        )
        existentes = {
            chave: {"skatista_id": skatista_id}
            for chave, skatista_id in connection.execute(
                """
                SELECT DISTINCT chave_origem, skatista_id
                FROM cadastro.inscricoes WHERE evento_id = %s
                """,
                (evento_id,),
            ).fetchall()
        }
        # A carga inicial continua exigindo revisão se uma identidade histórica
        # deixar de ser encontrada. Novas inscrições do Master podem coexistir.
        if existentes and not {r.chave for r in registros} <= existentes.keys():
            raise ValueError(
                "Identidades divergentes: revise a correção explicitamente antes da carga."
            )
        maior_numero = connection.execute(
            "SELECT coalesce(max(numero_provisorio), 0) FROM cadastro.inscricoes WHERE evento_id=%s",
            (evento_id,),
        ).fetchone()[0]
        for numero, registro in enumerate(registros, start=maior_numero + 1):
            gravar_registro(
                connection,
                evento_id,
                categorias,
                registro,
                existentes.get(registro.chave),
                numero,
            )
    return {"inscricoes": len(registros), "categorias": [3, 3, 6]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", type=Path, default=PRIVATE_CSV)
    args = parser.parse_args()
    try:
        resultado = importar(
            args.csv, import_database_url(), get_settings().evento_codigo
        )
    except (ValueError, OSError) as error:
        # OSError pode conter caminhos privados; não imprimir a exceção.
        print(
            str(error)
            if isinstance(error, ValueError)
            else "Não foi possível ler o CSV privado."
        )
        return 1
    except psycopg.Error:
        print(
            "Falha no banco. Transação cancelada; confira conexão, migração e permissões."
        )
        return 1
    print(
        f"Importação concluída: {resultado['inscricoes']} inscrições; categorias 3/3/6."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
