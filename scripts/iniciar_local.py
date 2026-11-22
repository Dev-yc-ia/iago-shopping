"""Iniciador local: porta exclusiva, espera limitada e nenhum encerramento de processos alheios."""

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import webbrowser

import psycopg
from psycopg.conninfo import conninfo_to_dict

from backend.config.paths import PROJECT_DIR
from backend.config.settings import get_settings
from backend.db import read_connection

HOST = "127.0.0.1"
PORTA = 8095
URL = f"http://{HOST}:{PORTA}/"
LOG = PROJECT_DIR / "dados_privados" / "inicializacao_8095.log"


def banco_disponivel():
    try:
        with read_connection(get_settings()) as connection:
            connection.execute("SELECT 1 FROM cadastro.inscricoes LIMIT 1")
        return True
    except (psycopg.Error, ValueError):
        return False


def preparar_banco():
    if banco_disponivel():
        return True
    host = conninfo_to_dict(get_settings().database_url).get("host")
    if host not in {None, "localhost", "127.0.0.1", "::1"}:
        print("Banco remoto indisponivel. Confira a conexao privada.")
        return False
    npx = shutil.which("npx.cmd" if os.name == "nt" else "npx")
    if not npx:
        print(
            "Banco indisponivel. Abra o Docker Desktop e confira a configuracao local."
        )
        return False
    print("Aguardando banco local. O Docker Desktop precisa estar aberto...")
    try:
        resultado = subprocess.run(
            check=False,
            args=[
                npx,
                "--yes",
                "supabase@3.2.0",
                "db",
                "start",
                "--network-id",
                "iago_system_loopback",
            ],
            cwd=PROJECT_DIR,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=120,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        return resultado.returncode == 0 and banco_disponivel()
    except (OSError, subprocess.TimeoutExpired):
        return False


def porta_ocupada():
    with socket.socket() as conexao:
        conexao.settimeout(1)
        return conexao.connect_ex((HOST, PORTA)) == 0


def programa_responde():
    """Verifica a identidade da pagina e o contrato sem imprimir dados pessoais."""
    try:
        with urllib.request.urlopen(URL, timeout=2) as resposta:
            html = resposta.read().decode("utf-8")
        if "Ranking · Iago System ACSN" not in html:
            return False
        with urllib.request.urlopen(URL + "api/ranking", timeout=3) as resposta:
            dados = json.load(resposta)
        return isinstance(dados.get("categorias"), list) and isinstance(
            dados.get("inscricoes"), list
        )
    except (OSError, ValueError):
        return False


def iniciar(abrir_navegador=True):
    if porta_ocupada():
        if not programa_responde():
            print(
                "A porta 8095 esta ocupada ou a API esta indisponivel. Nenhum processo foi encerrado."
            )
            print("Confira o programa nessa porta e a conexao com o banco local.")
            return 1
        print("O Iago System ja esta aberto na porta 8095.")
    else:
        if not preparar_banco():
            print(
                "Nao foi possivel acessar o banco. Abra o Docker Desktop e confira o .env privado."
            )
            return 1
        LOG.parent.mkdir(parents=True, exist_ok=True)
        print("Iniciando Iago System na porta 8095...")
        with LOG.open("a", encoding="utf-8") as log:
            processo = subprocess.Popen(
                [
                    sys.executable,
                    "-m",
                    "uvicorn",
                    "backend.app:app",
                    "--host",
                    HOST,
                    "--port",
                    str(PORTA),
                    "--no-access-log",
                    "--no-proxy-headers",
                ],
                cwd=PROJECT_DIR,
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=log,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
            )
        limite = time.monotonic() + 30
        while time.monotonic() < limite:
            if programa_responde():
                break
            if processo.poll() is not None:
                break
            time.sleep(0.5)
        else:
            print(
                "Tempo de inicializacao excedido. Confira o log privado de inicializacao."
            )
            return 1
        if not programa_responde():
            print(
                "A inicializacao falhou. Confira dados_privados/inicializacao_8095.log."
            )
            return 1
    print(f"Pronto: {URL}")
    if abrir_navegador:
        webbrowser.open(URL)
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sem-navegador", action="store_true")
    argumentos = parser.parse_args()
    try:
        raise SystemExit(iniciar(not argumentos.sem_navegador))
    except OSError:
        print("Nao foi possivel iniciar. Confira os arquivos e permissoes locais.")
        raise SystemExit(1) from None
