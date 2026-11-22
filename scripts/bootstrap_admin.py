"""Bootstrap explícito e idempotente da homologação. Nunca redefine conta existente."""

import getpass
import os

import psycopg
from dotenv import load_dotenv
from psycopg.conninfo import conninfo_to_dict

from backend.config.paths import ENV_FILE
from backend.security import HASHER


def bootstrap(database_url, senha):
    """Somente conexão local; a senha temporária exige troca no primeiro acesso."""
    if conninfo_to_dict(database_url).get("host") not in {
        "127.0.0.1",
        "localhost",
        "::1",
    }:
        raise ValueError("Bootstrap permitido somente em loopback.")
    with psycopg.connect(database_url, connect_timeout=5) as c:
        if c.execute("SELECT 1 FROM operacao.usuarios WHERE login='admin'").fetchone():
            return False
        if not senha:
            raise ValueError("Informe a senha inicial local.")
        resultado = c.execute(
            """INSERT INTO operacao.usuarios(nome,login,senha_hash,perfil,trocar_senha)
                              VALUES ('Administrador','admin',%s,'master',true)
                              ON CONFLICT (login) DO NOTHING RETURNING id""",
            (HASHER.hash(senha),),
        ).fetchone()
        return bool(resultado)


def main():
    load_dotenv(ENV_FILE, override=False)
    senha = getpass.getpass("Senha inicial local do admin (entrada oculta): ")
    try:
        criado = bootstrap(os.environ["ADMIN_DATABASE_URL"], senha)
    except (KeyError, ValueError, psycopg.Error):
        print("Bootstrap não concluído. Confira a configuração local e a migração.")
        return 1
    print(
        "Master criado com troca obrigatória."
        if criado
        else "Conta existente preservada; nenhuma senha foi redefinida."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
