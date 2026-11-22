"""Senhas Argon2id e sessões opacas; nenhum segredo vai para o frontend ou logs."""

import hashlib
import re
import secrets
from datetime import UTC, datetime, timedelta

from argon2 import PasswordHasher, Type
from argon2.exceptions import InvalidHashError, VerificationError
from fastapi import HTTPException

HASHER = PasswordHasher(time_cost=2, memory_cost=19456, parallelism=1, type=Type.ID)
DUMMY_HASH = HASHER.hash(secrets.token_urlsafe(32))
COOKIE = "iago_session"


def hash_token(value):
    return hashlib.sha256(value.encode()).hexdigest()


def verificar_senha(hash_salvo, senha):
    try:
        return HASHER.verify(hash_salvo, senha)
    except (VerificationError, InvalidHashError):
        return False

def senha_forte(senha):
    if len(senha) < 6:
        raise HTTPException(400, "Use ao menos 6 caracteres.")


def nova_sessao(connection, usuario_id, horas):
    token = secrets.token_urlsafe(32)
    csrf = secrets.token_urlsafe(32)
    connection.execute(
        """INSERT INTO operacao.sessoes (token_hash,usuario_id,csrf_token,expira_em)
           VALUES (%s,%s,%s,%s)""",
        (
            hash_token(token),
            usuario_id,
            csrf,
            datetime.now(UTC) + timedelta(hours=horas),
        ),
    )
    return token, csrf


def cookie_sessao(response, token, request, horas):
    response.set_cookie(
        COOKIE,
        token,
        max_age=horas * 3600,
        httponly=True,
        samesite="strict",
        secure=request.url.scheme == "https",
        path="/",
    )


def sessao(
    connection,
    request,
    obrigatoria=True,
    perfil=None,
    permitir_troca=False,
    bloquear=False,
):
    token = request.cookies.get(COOKIE, "")
    if not token or len(token) > 200:
        usuario = None
    else:
        usuario = connection.execute(
            """SELECT u.id,u.nome,u.login,u.perfil,u.ativo,u.trocar_senha,
                      s.token_hash,s.csrf_token
               FROM operacao.sessoes s JOIN operacao.usuarios u ON u.id=s.usuario_id
               WHERE s.token_hash=%s AND s.expira_em>now() AND u.ativo"""
            + (" FOR SHARE OF u" if bloquear else ""),
            (hash_token(token),),
        ).fetchone()
    if not usuario:
        if obrigatoria:
            raise HTTPException(401, "Entre para continuar.")
        return None
    if usuario["trocar_senha"] and not permitir_troca:
        raise HTTPException(403, "Altere a senha antes de continuar.")
    if perfil and usuario["perfil"] != perfil:
        raise HTTPException(403, "Ação não permitida para esta conta.")
    if request.method not in {"GET", "HEAD", "OPTIONS"}:
        recebido = request.headers.get("x-csrf-token", "")
        if not secrets.compare_digest(recebido, usuario["csrf_token"]):
            raise HTTPException(
                403, "Confirmação de segurança inválida. Atualize a página."
            )
    return usuario


def serializar_sessao(usuario):
    if not usuario:
        return {"autenticado": False}
    return {
        "autenticado": True,
        "id": str(usuario["id"]),
        "nome": usuario["nome"],
        "login": usuario["login"],
        "perfil": usuario["perfil"],
        "trocar_senha": usuario["trocar_senha"],
        "csrf_token": usuario["csrf_token"],
    }
