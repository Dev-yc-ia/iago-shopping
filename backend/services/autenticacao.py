"""Login limitado, troca de senha e contas de juiz sem exposição de hashes."""

import re

from fastapi import HTTPException
from psycopg.errors import UniqueViolation

from backend.db import read_connection, write_connection
from backend.security import (
    DUMMY_HASH,
    HASHER,
    hash_token,
    nova_sessao,
    senha_forte,
    serializar_sessao,
    sessao,
    verificar_senha,
)


def consultar_sessao(settings, request):
    with read_connection(settings) as c:
        return serializar_sessao(
            sessao(c, request, obrigatoria=False, permitir_troca=True)
        )


def entrar(settings, login, senha, request):
    login = login.strip().lower()
    chave = hash_token(login + "|" + request.client.host)
    with write_connection(settings) as c:
        c.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", (chave,))
        c.execute(
            "DELETE FROM operacao.login_falhas WHERE horario<now()-interval '15 minutes'"
        )
        falhas = c.execute(
            "SELECT count(*) AS n FROM operacao.login_falhas WHERE chave=%s", (chave,)
        ).fetchone()["n"]
        if falhas >= 5:
            raise HTTPException(
                429, "Não foi possível entrar. Aguarde e tente novamente."
            )
        usuario = c.execute(
            "SELECT id,senha_hash,ativo FROM operacao.usuarios WHERE login=%s FOR SHARE",
            (login,),
        ).fetchone()
        valida = verificar_senha(
            usuario["senha_hash"] if usuario else DUMMY_HASH, senha
        )
        if not usuario or not usuario["ativo"] or not valida:
            c.execute("INSERT INTO operacao.login_falhas(chave) VALUES (%s)", (chave,))
            token = None
        else:
            c.execute("DELETE FROM operacao.login_falhas WHERE chave=%s", (chave,))
            token, _ = nova_sessao(c, usuario["id"], settings.session_hours)
    # A resposta inválida ocorre DEPOIS do commit do contador de falhas.
    if not token:
        raise HTTPException(401, "Login ou senha inválidos.")
    return token


def trocar_senha(settings, request, atual, nova, confirmacao):
    senha_forte(nova)
    if nova != confirmacao or nova == atual:
        raise HTTPException(400, "Confirme uma nova senha diferente da atual.")
    with write_connection(settings) as c:
        usuario = sessao(c, request, permitir_troca=True)
        alvo = c.execute(
            "SELECT senha_hash FROM operacao.usuarios WHERE id=%s FOR UPDATE",
            (usuario["id"],),
        ).fetchone()
        # Revalidar a sessão após obter a trava impede troca concorrente com token revogado.
        sessao(c, request, permitir_troca=True)
        if not verificar_senha(alvo["senha_hash"], atual):
            raise HTTPException(
                400, "Não foi possível alterar a senha. Confira os campos."
            )
        c.execute(
            "UPDATE operacao.usuarios SET senha_hash=%s,trocar_senha=false WHERE id=%s",
            (HASHER.hash(nova), usuario["id"]),
        )
        c.execute("DELETE FROM operacao.sessoes WHERE usuario_id=%s", (usuario["id"],))
        token, _ = nova_sessao(c, usuario["id"], settings.session_hours)
    return token


def sair(settings, request):
    with write_connection(settings) as c:
        usuario = sessao(c, request, permitir_troca=True)
        c.execute(
            "DELETE FROM operacao.sessoes WHERE token_hash=%s", (usuario["token_hash"],)
        )


def listar_juizes(settings, request):
    with read_connection(settings) as c:
        sessao(c, request, perfil="master")
        rows = c.execute(
            "SELECT id,nome,login,ativo,trocar_senha FROM operacao.usuarios WHERE perfil='juiz' ORDER BY nome,id"
        ).fetchall()
    return {"usuarios": [{**r, "id": str(r["id"])} for r in rows]}


def cadastrar_juiz(settings, request, nome, login, senha):
    senha_forte(senha)
    login = login.strip().lower()
    if not re.fullmatch(r"[a-z0-9_.-]{3,60}", login) or not nome.strip():
        raise HTTPException(
            400,
            "Informe nome e login válido com 3 a 60 letras, números, ponto, hífen ou sublinhado.",
        )
    try:
        with write_connection(settings) as c:
            from backend.services.votacao import bloquear_evento

            bloquear_evento(c, settings)
            sessao(c, request, perfil="master", bloquear=True)
            c.execute(
                """INSERT INTO operacao.usuarios(nome,login,senha_hash,perfil)
                         VALUES (%s,%s,%s,'juiz')""",
                (nome.strip(), login, HASHER.hash(senha)),
            )
    except UniqueViolation:
        raise HTTPException(409, "Login indisponível.") from None
    return {
        "mensagem": "Juiz cadastrado. A senha deve ser alterada no primeiro acesso."
    }


def ativar_juiz(settings, request, usuario_id, ativo):
    with write_connection(settings) as c:
        from backend.services.votacao import bloquear_evento

        bloquear_evento(c, settings)
        sessao(c, request, perfil="master", bloquear=True)
        alvo = c.execute(
            "UPDATE operacao.usuarios SET ativo=%s WHERE id=%s AND perfil='juiz' RETURNING id",
            (ativo, usuario_id),
        ).fetchone()
        if not alvo:
            raise HTTPException(404, "Juiz não encontrado.")
        if not ativo:
            c.execute("DELETE FROM operacao.sessoes WHERE usuario_id=%s", (usuario_id,))
    return {"mensagem": "Status atualizado. A banca já aberta permanece congelada."}
