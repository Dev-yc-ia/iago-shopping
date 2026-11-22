"""Conexões curtas, somente leitura, sem expor detalhes de falhas."""

from contextlib import contextmanager

import psycopg
from psycopg.rows import dict_row

from backend.config.settings import Settings


@contextmanager
def read_connection(settings: Settings):
    """Além das permissões da role, impõe transação de leitura no runtime."""
    if not settings.database_url:
        raise psycopg.OperationalError("Conexão não configurada.")
    with psycopg.connect(
        settings.database_url,
        connect_timeout=settings.connect_timeout,
        row_factory=dict_row,
    ) as connection:
        connection.execute("SET TRANSACTION READ ONLY")
        connection.execute("SET LOCAL statement_timeout=5000")
        yield connection


@contextmanager
def write_connection(settings: Settings):
    """Escrita limitada ao schema operacao pelas ACLs da conta de runtime."""
    if not settings.database_url:
        raise psycopg.OperationalError("Conexão não configurada.")
    with psycopg.connect(
        settings.database_url,
        connect_timeout=settings.connect_timeout,
        row_factory=dict_row,
    ) as connection:
        connection.execute("SET TRANSACTION READ WRITE")
        connection.execute("SET LOCAL statement_timeout=10000")
        connection.execute("SET LOCAL lock_timeout=8000")
        yield connection
