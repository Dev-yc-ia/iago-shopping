"""Contratos autenticados; corpo inválido nunca devolve senha ou nota na mensagem."""

from typing import Annotated, Literal
from uuid import UUID

import psycopg
from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field, StrictStr

from backend.config.settings import Settings, get_settings
from backend.security import COOKIE, cookie_sessao
from backend.services import autenticacao, votacao

router = APIRouter(prefix="/api")
Config = Annotated[Settings, Depends(get_settings)]


class Login(BaseModel):
    login: StrictStr = Field(max_length=60)
    senha: StrictStr = Field(repr=False)


class Senha(BaseModel):
    atual: StrictStr = Field(repr=False)
    nova: StrictStr = Field(repr=False)
    confirmacao: StrictStr = Field(repr=False)


class Juiz(Login):
    nome: StrictStr = Field(min_length=1, max_length=120)


class Status(BaseModel):
    ativo: bool = Field(strict=True)


class Abertura(BaseModel):
    inscricao_id: UUID
    volta: Literal[1, 2]


class Cancelamento(BaseModel):
    motivo: StrictStr = Field(max_length=500)


class Voto(BaseModel):
    nota: StrictStr = Field(max_length=64)


@router.get("/sessao")
def sessao(request: Request, settings: Config):
    return autenticacao.consultar_sessao(settings, request)


@router.post("/auth/login")
def entrar(dados: Login, request: Request, response: Response, settings: Config):
    token = autenticacao.entrar(settings, dados.login, dados.senha, request)
    cookie_sessao(response, token, request, settings.session_hours)
    return {"mensagem": "Acesso confirmado."}


@router.post("/auth/senha")
def senha(dados: Senha, request: Request, response: Response, settings: Config):
    token = autenticacao.trocar_senha(
        settings, request, dados.atual, dados.nova, dados.confirmacao
    )
    cookie_sessao(response, token, request, settings.session_hours)
    return {"mensagem": "Senha alterada. Outras sessões foram revogadas."}


@router.post("/auth/logout")
def sair(request: Request, response: Response, settings: Config):
    autenticacao.sair(settings, request)
    response.delete_cookie(COOKIE, path="/")
    return {"mensagem": "Sessão encerrada."}


@router.get("/usuarios")
def usuarios(request: Request, settings: Config):
    return autenticacao.listar_juizes(settings, request)


@router.post("/usuarios", status_code=201)
def cadastrar(dados: Juiz, request: Request, settings: Config):
    return autenticacao.cadastrar_juiz(
        settings, request, dados.nome, dados.login, dados.senha
    )


@router.patch("/usuarios/{usuario_id}")
def ativar(usuario_id: UUID, dados: Status, request: Request, settings: Config):
    return autenticacao.ativar_juiz(settings, request, usuario_id, dados.ativo)


@router.get("/competicao/estado")
def estado(request: Request, settings: Config):
    return votacao.estado_privado(settings, request)


@router.post("/competicao/chamar")
def chamar(dados: Abertura, request: Request, settings: Config):
    return votacao.preparar_tentativa(
        settings, request, dados.inscricao_id, dados.volta, False
    )


@router.post("/competicao/abrir")
def abrir(dados: Abertura, request: Request, settings: Config):
    return votacao.preparar_tentativa(
        settings, request, dados.inscricao_id, dados.volta, True
    )


@router.post("/competicao/{tentativa_id}/cancelar")
def cancelar(
    tentativa_id: UUID, dados: Cancelamento, request: Request, settings: Config
):
    return votacao.cancelar(settings, request, tentativa_id, dados.motivo)


@router.post("/competicao/{tentativa_id}/votos")
def votar(tentativa_id: UUID, dados: Voto, request: Request, settings: Config):
    try:
        return votacao.votar(settings, request, tentativa_id, dados.nota)
    except psycopg.errors.UniqueViolation as erro:
        if erro.diag.constraint_name != "um_resultado_por_volta_dia":
            raise
        raise HTTPException(
            409, "Esta volta já tem resultado publicado neste dia."
        ) from None


class Filtro(BaseModel):
    grupo: StrictStr = Field(min_length=1, max_length=100)


@router.post("/competicao/filtro")
def filtro(dados: Filtro, request: Request, settings: Config):
    return votacao.publicar_filtro(settings, request, dados.grupo)
