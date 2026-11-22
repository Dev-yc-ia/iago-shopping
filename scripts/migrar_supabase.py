"""Cópia transacional da homologação. Execute com as gravações suspensas."""

import argparse
import json
import os
import shutil
import subprocess
from datetime import UTC, datetime
from pathlib import Path

import psycopg
from dotenv import dotenv_values
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo
from psycopg.rows import dict_row

from backend.config.paths import ENV_FILE, MIGRATIONS_DIR

REFERENCIA = "yoewqaatkoltozppohxu"
TABELAS = (
    ("cadastro", "eventos"),
    ("cadastro", "categorias"),
    ("cadastro", "skatistas"),
    ("cadastro", "inscricoes"),
    ("operacao", "usuarios"),
    ("operacao", "tentativas"),
    ("operacao", "bancas"),
    ("operacao", "votos"),
    ("operacao", "controle_evento"),
)
EXCLUIDAS = (("operacao", "sessoes"), ("operacao", "login_falhas"))


def destino_validado(url):
    try:
        cfg = conninfo_to_dict(url)
    except psycopg.Error:
        raise ValueError("Conexão de migração inválida.") from None
    host = cfg.get("host", "")
    usuario = cfg.get("user", "")
    direto = host == f"db.{REFERENCIA}.supabase.co"
    pooler = (
        host.endswith(".pooler.supabase.com") and usuario == f"postgres.{REFERENCIA}"
    )
    if not (direto or pooler) or cfg.get("hostaddr") or "," in host:
        raise ValueError("Destino não corresponde à referência esperada do Supabase.")
    if cfg.get("port", "5432") != "5432":
        raise ValueError("Use conexão direta ou Session pooler na porta 5432.")
    return make_conninfo(url, sslmode="require", connect_timeout=8)


def backup_privado(origem, pasta, snapshot):
    dump, restore = shutil.which("pg_dump"), shutil.which("pg_restore")
    if not dump or not restore:
        raise ValueError("pg_dump e pg_restore precisam estar no PATH.")
    pasta.mkdir(exist_ok=True)
    destino = pasta / f"iago_origem_{datetime.now(UTC):%Y%m%d_%H%M%S_%f}.dump"
    # A senha permanece no ambiente do subprocesso e seu diagnóstico é suprimido.
    nomes_pg = {
        "dbname": "PGDATABASE",
        "host": "PGHOST",
        "hostaddr": "PGHOSTADDR",
        "port": "PGPORT",
        "user": "PGUSER",
        "password": "PGPASSWORD",
        "sslmode": "PGSSLMODE",
        "sslrootcert": "PGSSLROOTCERT",
    }
    env = dict(os.environ)
    cfg = conninfo_to_dict(origem)
    for campo, var in nomes_pg.items():
        env.pop(var, None)
        if campo in cfg:
            env[var] = cfg[campo]
    env["PGCONNECT_TIMEOUT"] = "8"
    subprocess.run(
        [
            dump,
            "-Fc",
            "--schema=cadastro",
            "--schema=operacao",
            "--no-password",
            f"--snapshot={snapshot}",
            "--file",
            str(destino),
        ],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=True,
    )
    subprocess.run(
        [restore, "--file", os.devnull, str(destino)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=True,
    )
    return destino.name


def colunas(c, esquema, tabela):
    return [
        row["column_name"]
        for row in c.execute(
            """SELECT column_name FROM information_schema.columns
        WHERE table_schema=%s AND table_name=%s AND is_generated='NEVER'
        ORDER BY ordinal_position""",
            (esquema, tabela),
        )
    ]


def selecionar(c, esquema, tabela, campos):
    return c.execute(
        sql.SQL("SELECT {} FROM {}").format(
            sql.SQL(",").join(map(sql.Identifier, campos)),
            sql.Identifier(esquema, tabela),
        )
    ).fetchall()


def chave(tabela, linha):
    if tabela == "bancas":
        return linha["evento_id"], linha["tentativa_id"], linha["juiz_id"]
    if tabela == "controle_evento":
        return linha["evento_id"]
    return linha["id"]


def copiar(origem, destino, esquema, tabela, atual):
    col_origem = colunas(origem, esquema, tabela)
    campos = colunas(destino, esquema, tabela)
    comparaveis = [campo for campo in campos if campo != "dia_volta"]
    if set(col_origem) - set(comparaveis) != (
        {"categoria_confirmada_id"}
        if atual and tabela == "inscricoes" and "categoria_confirmada_id" in col_origem
        else set()
    ) or not set(comparaveis) <= set(col_origem):
        raise ValueError(f"Esquema divergente em {esquema}.{tabela}.")
    registros = selecionar(origem, esquema, tabela, comparaveis)
    anteriores = {
        chave(tabela, linha): linha
        for linha in selecionar(destino, esquema, tabela, comparaveis)
    }
    if anteriores and anteriores != {
        chave(tabela, linha): linha for linha in registros
    }:
        raise ValueError(f"Dados divergentes em {esquema}.{tabela}.")
    if not anteriores and registros:
        if atual:
            raise ValueError(
                f"Destino já transformado e incompleto em {esquema}.{tabela}."
            )
        comando = sql.SQL("INSERT INTO {} ({}) VALUES ({})").format(
            sql.Identifier(esquema, tabela),
            sql.SQL(",").join(map(sql.Identifier, comparaveis)),
            sql.SQL(",").join(sql.Placeholder() for _ in comparaveis),
        )
        with destino.cursor() as cursor:
            cursor.executemany(
                comando,
                ([linha[campo] for campo in comparaveis] for linha in registros),
            )
    depois = selecionar(destino, esquema, tabela, comparaveis)
    if {chave(tabela, linha): linha for linha in depois} != {
        chave(tabela, linha): linha for linha in registros
    }:
        raise ValueError(f"Falha na reconciliação de {esquema}.{tabela}.")
    return len(registros)


def migrar(origem_url, destino_url, pasta):
    arquivos = sorted(MIGRATIONS_DIR.glob("*.sql"))
    with psycopg.connect(origem_url, row_factory=dict_row, connect_timeout=8) as origem:
        origem.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        origem.execute("SET LOCAL lock_timeout='10s'")
        origem.execute(
            sql.SQL("LOCK TABLE {} IN SHARE MODE").format(
                sql.SQL(",").join(sql.Identifier(*item) for item in TABELAS)
            )
        )
        snapshot = origem.execute("SELECT pg_export_snapshot() AS id").fetchone()["id"]
        nome_backup = backup_privado(origem_url, pasta, snapshot)
        if origem.execute(
            "SELECT 1 FROM operacao.tentativas WHERE estado IN ('aberta','chamada') LIMIT 1"
        ).fetchone():
            raise ValueError(
                "Origem com tentativa ativa. Backup gerado; migração interrompida."
            )
        divergentes = origem.execute(
            """SELECT count(*) AS n FROM cadastro.inscricoes WHERE categoria_confirmada_id IS NOT NULL
            AND categoria_confirmada_id<>categoria_base_id"""
        ).fetchone()["n"]
        with psycopg.connect(destino_url, row_factory=dict_row) as destino:
            destino.execute(
                "SELECT pg_advisory_xact_lock(hashtext('iago_system_migracao'))"
            )
            schemas = destino.execute(
                "SELECT count(*) AS n FROM pg_namespace WHERE nspname IN ('cadastro','operacao')"
            ).fetchone()["n"]
            if schemas == 1:
                raise ValueError("Destino possui estrutura parcial.")
            atual = False
            if schemas == 0:
                for arquivo in arquivos[:-1]:
                    destino.execute(arquivo.read_text(encoding="utf-8"))
            else:
                destino.execute(
                    sql.SQL("LOCK TABLE {} IN SHARE ROW EXCLUSIVE MODE").format(
                        sql.SQL(",").join(
                            sql.Identifier(*item) for item in (*TABELAS, *EXCLUIDAS)
                        )
                    )
                )
                atual = "dia_volta" in colunas(destino, "operacao", "tentativas")
                if not atual:
                    for esquema, tabela in EXCLUIDAS:
                        if destino.execute(
                            sql.SQL("SELECT 1 FROM {} LIMIT 1").format(
                                sql.Identifier(esquema, tabela)
                            )
                        ).fetchone():
                            raise ValueError(
                                "Destino contém atividade de login anterior ao corte."
                            )
            contagens = {
                f"{esquema}.{tabela}": copiar(origem, destino, esquema, tabela, atual)
                for esquema, tabela in TABELAS
            }
            if not atual:
                destino.execute(arquivos[-1].read_text(encoding="utf-8"))
            historico = destino.execute(
                """WITH primeiros AS (
                    SELECT evento_id,tentativa_id,
                    (min(horario) AT TIME ZONE 'America/Sao_Paulo')::date AS dia
                    FROM operacao.votos GROUP BY evento_id,tentativa_id
                )
                SELECT count(*) FILTER (WHERE t.estado='concluida' AND p.dia IS NULL) AS concluidas_sem_voto,
                       count(*) FILTER (WHERE t.dia_volta IS DISTINCT FROM p.dia) AS datas_divergentes
                FROM operacao.tentativas t LEFT JOIN primeiros p
                ON (p.evento_id,p.tentativa_id)=(t.evento_id,t.id)"""
            ).fetchone()
            if historico["datas_divergentes"]:
                raise ValueError("Datas históricas divergentes.")
    return {
        "backup_verificado": nome_backup,
        "tabelas_reconciliadas": contagens,
        "categorias_confirmadas_divergentes": divergentes,
        "historico": historico,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executar", action="store_true", required=True)
    parser.parse_args()
    cfg = dotenv_values(ENV_FILE)
    try:
        destino = destino_validado(cfg["SUPABASE_MIGRATION_URL"])
        resultado = migrar(
            cfg["ADMIN_DATABASE_URL"], destino, Path(ENV_FILE).parent / "dados_privados"
        )
    except (KeyError, TypeError, psycopg.Error, subprocess.SubprocessError, OSError):
        print(
            "Migração interrompida. Confira conexões, esquema e ferramentas de backup."
        )
        return 1
    except ValueError as erro:
        print(str(erro))
        return 1
    print(json.dumps(resultado, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
