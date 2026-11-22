"""Ranking público e rotas privadas do cadastro e das notas."""

import json
from dataclasses import replace
from datetime import date
from typing import Annotated
from uuid import UUID

import psycopg
from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field, ValidationError
from starlette.concurrency import run_in_threadpool

from backend.config.settings import Settings, get_settings
from backend.db import read_connection
from backend.security import sessao
from backend.services import avatar, cadastro_skatistas, skatistas


class CadastroSkatista(BaseModel):
    nome: str = Field(max_length=200)
    escola: str = Field(max_length=200)
    nascimento: date
    sexo: str = Field(max_length=20)
    categoria: str | None = Field(default=None, max_length=200)
    categorias: list[str] | None = Field(default=None, min_length=1, max_length=4)


router = APIRouter(prefix="/api")


def consultar(consulta, settings: Settings):
    """Não registra exceções SQL, que podem conter dados ou credenciais."""
    try:
        return consulta(settings)
    except psycopg.Error:
        raise HTTPException(
            status_code=503,
            detail="Banco local indisponível. Confira a conexão e tente novamente.",
        ) from None


@router.get("/ranking")
def obter_ranking(
    settings: Annotated[Settings, Depends(get_settings)],
):
    """Categorias ordenadas e campos mínimos para o placar."""
    return consultar(skatistas.ranking, settings)


@router.get("/skatistas")
def obter_skatistas(
    request: Request, settings: Annotated[Settings, Depends(get_settings)]
):
    """Dados locais de credenciamento, somente leitura."""

    def obter(config):
        with read_connection(config) as connection:
            sessao(connection, request, perfil="master")
        return skatistas.credenciamento(config)

    return consultar(obter, settings)


async def ler_cadastro(request, settings, *, edicao=False):
    def autorizar(config):
        with read_connection(config) as connection:
            sessao(connection, request, perfil="master")

    await run_in_threadpool(consultar, autorizar, settings)
    conteudo = bytearray()
    async for parte in request.stream():
        if len(conteudo) + len(parte) > avatar.LIMITE_JSON:
            raise HTTPException(413, "Corpo da requisição excede o limite.")
        conteudo.extend(parte)
    try:
        bruto = json.loads(conteudo)
        dados = CadastroSkatista.model_validate(bruto)
        if ("categoria" in bruto) == ("categorias" in bruto):
            raise ValueError
        categorias = dados.categorias if "categorias" in bruto else [dados.categoria]
        if not categorias or any(not isinstance(valor, str) for valor in categorias):
            raise ValueError
        categorias = [valor.strip() for valor in categorias]
        if len(set(categorias)) != len(categorias):
            raise ValueError
        if (
            not isinstance(bruto.get("nascimento"), str)
            or bruto["nascimento"] != dados.nascimento.isoformat()
        ):
            raise ValueError
    except (ValueError, RecursionError, ValidationError):
        raise HTTPException(422, "Dados inválidos.") from None
    try:
        registro = cadastro_skatistas.validar_linha(
            (
                dados.nome,
                dados.escola,
                dados.nascimento,
                dados.nascimento.year,
                dados.sexo,
                categorias[0],
            ),
            settings.evento_codigo,
            1,
        )
    except ValueError as erro:
        raise HTTPException(422, str(erro)) from None
    return (
        registro,
        categorias if "categorias" in bruto else None,
        avatar.foto(bruto, edicao=edicao),
    )


@router.post("/skatistas")
async def cadastrar_skatista(
    request: Request,
    settings: Annotated[Settings, Depends(get_settings)],
):
    registro, categorias, png = await ler_cadastro(request, settings)
    return await run_in_threadpool(
        consultar,
        lambda config: cadastro_skatistas.gravar_lote(
            config,
            request,
            [
                (1, replace(registro, categoria=categoria))
                for categoria in (categorias or [registro.categoria])
            ],
            png,
        ),
        settings,
    )


@router.patch("/skatistas/{inscricao_id}")
async def editar_skatista(
    inscricao_id: UUID,
    request: Request,
    settings: Annotated[Settings, Depends(get_settings)],
):
    registro, categorias, png = await ler_cadastro(request, settings, edicao=True)
    return await run_in_threadpool(
        consultar,
        lambda config: cadastro_skatistas.editar(
            config, request, inscricao_id, registro, categorias, png
        ),
        settings,
    )


@router.get("/skatistas/{inscricao_id}/avatar")
def obter_avatar(
    inscricao_id: UUID,
    v: UUID,
    request: Request,
    settings: Annotated[Settings, Depends(get_settings)],
):
    def obter(config):
        with read_connection(config) as connection:
            return connection.execute(
                """SELECT f.png FROM cadastro.fotos_skatistas f
                JOIN cadastro.inscricoes i ON i.skatista_id=f.skatista_id
                JOIN cadastro.eventos e ON e.id=i.evento_id
                WHERE i.id=%s AND f.versao=%s AND e.codigo=%s""",
                (inscricao_id, v, config.evento_codigo),
            ).fetchone()

    imagem = consultar(obter, settings)
    if not imagem:
        raise HTTPException(
            404, "Foto indisponível.", headers={"Cache-Control": "no-store"}
        )
    etag = f'"{v}"'
    headers = {
        "Cache-Control": "public, no-cache",
        "ETag": etag,
        "X-Content-Type-Options": "nosniff",
    }
    if request.headers.get("if-none-match") == etag:
        return Response(status_code=304, headers=headers)
    return Response(bytes(imagem["png"]), media_type="image/png", headers=headers)


@router.post("/skatistas/importar")
async def importar_skatistas(
    request: Request,
    settings: Annotated[Settings, Depends(get_settings)],
    nome: str,
):
    def autorizar(config):
        with read_connection(config) as connection:
            sessao(connection, request, perfil="master")

    await run_in_threadpool(consultar, autorizar, settings)
    conteudo = bytearray()
    async for parte in request.stream():
        if len(conteudo) + len(parte) > cadastro_skatistas.LIMITE_BYTES:
            raise HTTPException(413, "Arquivo excede 2 MiB.")
        conteudo.extend(parte)

    def importar(config):
        try:
            registros = cadastro_skatistas.ler_planilha(
                nome, bytes(conteudo), config.evento_codigo
            )
        except ValueError as erro:
            raise HTTPException(422, str(erro)) from None
        return cadastro_skatistas.gravar_lote(config, request, registros)

    return await run_in_threadpool(consultar, importar, settings)


@router.get("/notas")
def consultar_notas(
    request: Request,
    settings: Annotated[Settings, Depends(get_settings)],
    dia: date,
):
    def consultar_dia(config):
        with read_connection(config) as connection:
            sessao(connection, request, perfil="master")
            return {
                "notas": connection.execute(
                    """SELECT n.* FROM operacao.notas_por_dia n JOIN cadastro.eventos e
                ON e.id=n.evento_id WHERE e.codigo=%s AND n.dia_voto=%s ORDER BY n.horario,n.id""",
                    (config.evento_codigo, dia),
                ).fetchall()
            }

    return consultar(consultar_dia, settings)
