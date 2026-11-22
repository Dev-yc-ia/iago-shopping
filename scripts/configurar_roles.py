"""Provisiona contas locais dedicadas; credenciais vêm somente do ambiente privado."""

import argparse
import os

import psycopg
from dotenv import load_dotenv
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict

from backend.config.paths import ENV_FILE


def conceder_operacao(connection):
    """Runtime escreve só nas tabelas operacionais; votos continuam imutáveis."""
    if not connection.execute("SELECT to_regnamespace('operacao')").fetchone()[0]:
        return
    connection.execute(
        "GRANT INSERT ON cadastro.skatistas, cadastro.inscricoes TO iago_runtime"
    )
    if connection.execute("SELECT to_regclass('cadastro.fotos_skatistas')").fetchone()[
        0
    ]:
        connection.execute(
            "GRANT SELECT, INSERT, UPDATE, DELETE ON cadastro.fotos_skatistas TO iago_runtime"
        )
        connection.execute(
            "GRANT UPDATE (nome, escola, data_nascimento, sexo_confirmado) ON cadastro.skatistas TO iago_runtime"
        )
        connection.execute(
            "GRANT UPDATE (categoria_base_id, chave_origem) ON cadastro.inscricoes TO iago_runtime"
        )
        if connection.execute(
            "SELECT 1 FROM pg_roles WHERE rolname = %s", ("iago_importador",)
        ).fetchone():
            connection.execute(
                "REVOKE ALL ON cadastro.fotos_skatistas FROM iago_importador"
            )
    funcoes = (
        (
            "cadastro.incluir_inscricao(uuid,text,text,text,date,text,text)",
            "iago_runtime",
        ),
        (
            "cadastro.editar_inscricoes(uuid,uuid,text,text,text,date,text,text[],boolean,boolean)",
            "iago_runtime",
        ),
        ("cadastro.retirar_inscricao(uuid,uuid)", "iago_runtime"),
        ("cadastro.provisionar_categorias(uuid)", "iago_importador"),
    )
    for assinatura, papel in funcoes:
        funcao, existe_papel = connection.execute(
            "SELECT to_regprocedure(%s), EXISTS (SELECT 1 FROM pg_roles WHERE rolname=%s)",
            (assinatura, papel),
        ).fetchone()
        if funcao and existe_papel:
            connection.execute(
                sql.SQL("GRANT EXECUTE ON FUNCTION {} TO {}").format(
                    sql.SQL(assinatura), sql.Identifier(papel)
                )
            )
    connection.execute("GRANT USAGE ON SCHEMA operacao TO iago_runtime")
    connection.execute("REVOKE ALL ON ALL TABLES IN SCHEMA operacao FROM iago_runtime")
    if connection.execute("SELECT to_regclass('operacao.notas_por_dia')").fetchone()[0]:
        connection.execute("GRANT SELECT ON operacao.notas_por_dia TO iago_runtime")
    connection.execute(
        "GRANT SELECT, INSERT, UPDATE ON operacao.controle_evento TO iago_runtime"
    )
    connection.execute(
        "GRANT SELECT, INSERT, UPDATE ON operacao.usuarios, operacao.tentativas TO iago_runtime"
    )
    connection.execute(
        "GRANT SELECT, INSERT ON operacao.bancas, operacao.votos TO iago_runtime"
    )
    connection.execute(
        "GRANT SELECT, INSERT, DELETE ON operacao.sessoes, operacao.login_falhas TO iago_runtime"
    )


def configurar(remoto=False) -> None:
    """Execute após migração, com conta administrativa no cluster exclusivo."""
    load_dotenv(ENV_FILE, override=False)
    if remoto:
        from scripts.migrar_supabase import REFERENCIA, destino_validado

        admin_url = destino_validado(os.environ["SUPABASE_MIGRATION_URL"])
    else:
        admin_url = os.environ["ADMIN_DATABASE_URL"]
    with psycopg.connect(admin_url, connect_timeout=5) as connection:
        database = connection.info.dbname
        for variavel, nome, permissoes in [
            ("DATABASE_URL", "iago_runtime", "SELECT"),
            ("IMPORT_DATABASE_URL", "iago_importador", "SELECT, INSERT, UPDATE"),
        ]:
            prefixo = "SUPABASE_" if remoto else ""
            credencial = conninfo_to_dict(os.environ[prefixo + variavel])
            usuario = credencial.get("user")
            nomes = {nome, f"{nome}.{REFERENCIA}"} if remoto else {nome}
            if usuario not in nomes or not credencial.get("password"):
                raise ValueError("Configure as contas dedicadas do .env.example.")
            if not connection.execute(
                "SELECT 1 FROM pg_roles WHERE rolname = %s", (nome,)
            ).fetchone():
                connection.execute(
                    sql.SQL("CREATE ROLE {} LOGIN").format(sql.Identifier(nome))
                )
            connection.execute(
                sql.SQL(
                    "ALTER ROLE {} WITH LOGIN NOCREATEDB NOCREATEROLE "
                    "NOINHERIT PASSWORD {}"
                ).format(sql.Identifier(nome), sql.Literal(credencial["password"]))
            )
            connection.execute(
                sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(
                    sql.Identifier(database), sql.Identifier(nome)
                )
            )
            connection.execute(
                sql.SQL("GRANT USAGE ON SCHEMA cadastro TO {}").format(
                    sql.Identifier(nome)
                )
            )
            connection.execute(
                sql.SQL("REVOKE ALL ON ALL TABLES IN SCHEMA cadastro FROM {}").format(
                    sql.Identifier(nome)
                )
            )
            connection.execute(
                sql.SQL(
                    "GRANT " + permissoes + " ON ALL TABLES IN SCHEMA cadastro TO {}"
                ).format(sql.Identifier(nome))
            )
        connection.execute(
            "ALTER ROLE iago_runtime SET default_transaction_read_only = on"
        )
        conceder_operacao(connection)
    print(
        "Contas configuradas: leitura de cadastro, operação limitada e importação separada."
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--supabase", action="store_true")
    args = parser.parse_args()
    try:
        configurar(args.supabase)
    except (KeyError, ValueError, psycopg.Error):
        print(
            "Falha no provisionamento. Confira migração e variáveis privadas; nenhum segredo exibido."
        )
        raise SystemExit(1) from None
