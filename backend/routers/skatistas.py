"""Ranking público e rotas privadas do cadastro e das notas."""

from datetime import date
from typing import Annotated

import psycopg
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool

from backend.config.settings import Settings, get_settings
from backend.db import read_connection
from backend.security import sessao
from backend.services import cadastro_skatistas, skatistas


class CadastroSkatista(BaseModel):
    nome: str = Field(max_length=200)
    escola: str = Field(max_length=200)
    nascimento: date
    sexo: str = Field(max_length=20)
    categoria: str = Field(max_length=200)


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


@router.post("/skatistas")
def cadastrar_skatista(
    dados: CadastroSkatista,
    request: Request,
    settings: Annotated[Settings, Depends(get_settings)],
):
    try:
        registro = cadastro_skatistas.validar_linha(
            (
                dados.nome,
                dados.escola,
                dados.nascimento,
                dados.nascimento.year,
                dados.sexo,
                dados.categoria,
            ),
            settings.evento_codigo,
            1,
        )
    except ValueError as erro:
        raise HTTPException(422, str(erro)) from None
    return consultar(
        lambda config: cadastro_skatistas.gravar_lote(config, request, [(1, registro)]),
        settings,
    )


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
