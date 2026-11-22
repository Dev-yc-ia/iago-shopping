"""Configuração por ambiente; credenciais nunca entram em respostas ou logs."""

import os
from dataclasses import dataclass, field

from dotenv import load_dotenv
from psycopg import Error
from psycopg.conninfo import make_conninfo

from backend.config.paths import ENV_FILE

load_dotenv(ENV_FILE, override=False)


@dataclass(frozen=True)
class Settings:
    database_url: str = field(repr=False)
    evento_codigo: str = "acsn-inicial"
    connect_timeout: int = 3
    session_hours: int = 8


def get_settings() -> Settings:
    """Lê a conta de runtime: leitura do cadastro e operação limitada por ACL."""
    remoto = os.getenv("IAGO_BANCO", "local") == "supabase"
    variavel = "SUPABASE_DATABASE_URL" if remoto else "DATABASE_URL"
    url = os.getenv(variavel, "")
    if remoto and url:
        try:
            url = make_conninfo(url, sslmode="require")
        except Error:
            url = ""
    return Settings(
        database_url=url,
        evento_codigo=os.getenv("EVENTO_CODIGO", "acsn-inicial"),
        connect_timeout=int(os.getenv("DB_CONNECT_TIMEOUT", "3")),
        session_hours=int(os.getenv("SESSION_HOURS", "8")),
    )


def import_database_url() -> str:
    """A carga exige credencial separada; não há fallback para o runtime."""
    value = os.getenv("IMPORT_DATABASE_URL", "")
    if not value:
        raise ValueError("Configure IMPORT_DATABASE_URL no ambiente privado.")
    return value
