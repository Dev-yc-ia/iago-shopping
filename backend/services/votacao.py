"""Pista persistida. Ordem de bloqueio: evento, conta e tentativa em toda mutação."""

import re
from decimal import ROUND_HALF_UP, Decimal

from fastapi import HTTPException

from backend.db import read_connection, write_connection
from backend.security import sessao


def bloquear_evento(c, settings):
    evento = c.execute(
        "SELECT id FROM cadastro.eventos WHERE codigo=%s", (settings.evento_codigo,)
    ).fetchone()
    if not evento:
        raise HTTPException(409, "Evento sem cadastro. Execute a importação local.")
    c.execute(
        "INSERT INTO operacao.controle_evento(evento_id) VALUES (%s) ON CONFLICT DO NOTHING",
        (evento["id"],),
    )
    c.execute(
        "SELECT evento_id FROM operacao.controle_evento WHERE evento_id=%s FOR UPDATE",
        (evento["id"],),
    )
    return evento["id"]


def tentativa_publica(c, tentativa):
    if not tentativa:
        return None
    atleta = c.execute(
        """SELECT s.nome,i.numero_provisorio,cat.codigo AS categoria,
        cat.id::text || ':' || s.sexo_confirmado AS grupo
        FROM cadastro.inscricoes i JOIN cadastro.skatistas s ON s.id=i.skatista_id
        JOIN cadastro.categorias cat ON cat.id=i.categoria_base_id
        WHERE i.id=%s AND i.evento_id=%s""",
        (tentativa["inscricao_id"], tentativa["evento_id"]),
    ).fetchone()
    return {
        "id": str(tentativa["id"]),
        "inscricao_id": str(tentativa["inscricao_id"]),
        "volta": tentativa["volta"],
        "estado": tentativa["estado"],
        **atleta,
    }


def atual(c, evento_id, bloquear=False):
    return c.execute(
        """SELECT * FROM operacao.tentativas
        WHERE evento_id=%s AND estado IN ('chamada','aberta')"""
        + (" FOR UPDATE" if bloquear else ""),
        (evento_id,),
    ).fetchone()


def preparar_tentativa(settings, request, inscricao_id, volta, abrir):
    with write_connection(settings) as c:
        evento_id = bloquear_evento(c, settings)
        usuario = sessao(c, request, perfil="master", bloquear=True)
        inscricao = c.execute(
            "SELECT id FROM cadastro.inscricoes WHERE evento_id=%s AND id=%s",
            (evento_id, inscricao_id),
        ).fetchone()
        if not inscricao:
            raise HTTPException(404, "Inscrição não encontrada neste evento.")
        if c.execute(
            "SELECT 1 FROM operacao.tentativas WHERE evento_id=%s AND inscricao_id=%s AND volta=%s AND estado='concluida' AND dia_volta=(clock_timestamp() AT TIME ZONE 'America/Sao_Paulo')::date",
            (evento_id, inscricao_id, volta),
        ).fetchone():
            raise HTTPException(409, "Esta volta já tem resultado publicado.")
        pista = atual(c, evento_id, bloquear=True)
        if pista and (
            str(pista["inscricao_id"]) != str(inscricao_id)
            or pista["volta"] != volta
            or pista["estado"] != "chamada"
            or not abrir
        ):
            raise HTTPException(
                409,
                "Já existe uma volta em pista. Conclua ou cancele antes de outra liberação.",
            )
        juizes = []
        if abrir:
            juizes = c.execute(
                "SELECT id FROM operacao.usuarios WHERE perfil='juiz' AND ativo ORDER BY id FOR SHARE"
            ).fetchall()
            if not juizes:
                raise HTTPException(
                    409, "Cadastre e ative pelo menos um juiz antes de liberar."
                )
        if pista:
            tentativa = c.execute(
                "UPDATE operacao.tentativas SET estado='aberta',aberta_em=now() WHERE id=%s RETURNING *",
                (pista["id"],),
            ).fetchone()
        else:
            tentativa = c.execute(
                """INSERT INTO operacao.tentativas
                (evento_id,inscricao_id,volta,estado,criada_por,aberta_em)
                VALUES (%s,%s,%s,%s,%s,CASE WHEN %s THEN now() ELSE NULL END) RETURNING *""",
                (
                    evento_id,
                    inscricao_id,
                    volta,
                    "aberta" if abrir else "chamada",
                    usuario["id"],
                    abrir,
                ),
            ).fetchone()
        for juiz in juizes:
            c.execute(
                "INSERT INTO operacao.bancas(evento_id,tentativa_id,juiz_id) VALUES (%s,%s,%s)",
                (evento_id, tentativa["id"], juiz["id"]),
            )
        return {"tentativa": tentativa_publica(c, tentativa)}


def cancelar(settings, request, tentativa_id, motivo):
    if not 3 <= len(motivo.strip()) <= 500:
        raise HTTPException(
            400, "Informe o motivo do cancelamento (3 a 500 caracteres)."
        )
    with write_connection(settings) as c:
        evento_id = bloquear_evento(c, settings)
        sessao(c, request, perfil="master", bloquear=True)
        tentativa = c.execute(
            "SELECT estado FROM operacao.tentativas WHERE id=%s AND evento_id=%s FOR UPDATE",
            (tentativa_id, evento_id),
        ).fetchone()
        if not tentativa:
            raise HTTPException(404, "Tentativa não encontrada.")
        if tentativa["estado"] not in {"chamada", "aberta"}:
            raise HTTPException(409, "A tentativa já foi encerrada.")
        c.execute(
            "UPDATE operacao.tentativas SET estado='cancelada',motivo_cancelamento=%s,encerrada_em=now() WHERE id=%s",
            (motivo.strip(), tentativa_id),
        )
    return {
        "mensagem": "Tentativa cancelada. Votos preservados internamente, sem resultado público."
    }


def validar_nota(entrada):
    texto = entrada.strip()
    if not re.fullmatch(r"\d{1,3}([.,]\d{1,2})?", texto):
        raise HTTPException(400, "Informe nota de 0 a 100 com até duas casas decimais.")
    nota = Decimal(texto.replace(",", "."))
    if nota < 0 or nota > 100:
        raise HTTPException(400, "A nota deve estar entre 0 e 100.")
    return nota


def recibo(voto, tentativa_id):
    return {
        "id": str(voto["id"]),
        "tentativa_id": str(tentativa_id),
        "nota": format(voto["nota"], ".2f"),
        "horario": voto["horario"].isoformat(),
    }


def votar(settings, request, tentativa_id, entrada):
    nota = validar_nota(entrada)
    with write_connection(settings) as c:
        evento_id = bloquear_evento(c, settings)
        usuario = sessao(c, request, perfil="juiz", bloquear=True)
        tentativa = c.execute(
            "SELECT * FROM operacao.tentativas WHERE id=%s AND evento_id=%s FOR UPDATE",
            (tentativa_id, evento_id),
        ).fetchone()
        if not tentativa:
            raise HTTPException(404, "Tentativa não encontrada.")
        if not c.execute(
            "SELECT 1 FROM operacao.bancas WHERE evento_id=%s AND tentativa_id=%s AND juiz_id=%s",
            (evento_id, tentativa_id, usuario["id"]),
        ).fetchone():
            raise HTTPException(403, "Sua conta não integra a banca desta tentativa.")
        if tentativa["estado"] == "cancelada":
            raise HTTPException(409, "Tentativa cancelada. Confira a volta atual.")
        anterior = c.execute(
            "SELECT id,nota,horario FROM operacao.votos WHERE evento_id=%s AND tentativa_id=%s AND juiz_id=%s",
            (evento_id, tentativa_id, usuario["id"]),
        ).fetchone()
        if anterior:
            if anterior["nota"] != nota:
                raise HTTPException(
                    409, "A nota já foi enviada e não pode ser substituída."
                )
            return {"recibo": recibo(anterior, tentativa_id)}
        if tentativa["estado"] != "aberta":
            raise HTTPException(409, "Esta tentativa não está recebendo notas.")
        voto = c.execute(
            "INSERT INTO operacao.votos(evento_id,tentativa_id,juiz_id,nota,horario) VALUES (%s,%s,%s,%s,clock_timestamp()) RETURNING id,nota,horario",
            (evento_id, tentativa_id, usuario["id"], nota),
        ).fetchone()
        if tentativa["dia_volta"] is None:
            dia = c.execute(
                "SELECT (%s::timestamptz AT TIME ZONE 'America/Sao_Paulo')::date AS dia",
                (voto["horario"],),
            ).fetchone()["dia"]
            if c.execute(
                """SELECT 1 FROM operacao.tentativas WHERE evento_id=%s
                AND inscricao_id=%s AND volta=%s AND estado='concluida' AND dia_volta=%s""",
                (evento_id, tentativa["inscricao_id"], tentativa["volta"], dia),
            ).fetchone():
                raise HTTPException(
                    409, "Esta volta já tem resultado publicado neste dia."
                )
            c.execute(
                "UPDATE operacao.tentativas SET dia_volta=%s WHERE id=%s",
                (dia, tentativa_id),
            )
        total = c.execute(
            "SELECT count(*) AS n FROM operacao.bancas WHERE evento_id=%s AND tentativa_id=%s",
            (evento_id, tentativa_id),
        ).fetchone()["n"]
        resultado = c.execute(
            "SELECT count(*) AS n,avg(nota) AS media FROM operacao.votos WHERE evento_id=%s AND tentativa_id=%s",
            (evento_id, tentativa_id),
        ).fetchone()
        if resultado["n"] == total:
            # Último voto e publicação compartilham commit; não há média parcial visível.
            media = resultado["media"].quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
            c.execute(
                "UPDATE operacao.tentativas SET estado='concluida',media=%s,encerrada_em=now() WHERE id=%s",
                (media, tentativa_id),
            )
        return {"recibo": recibo(voto, tentativa_id)}


def estado_privado(settings, request):
    with read_connection(settings) as c:
        c.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        usuario = sessao(c, request)
        evento = c.execute(
            "SELECT id FROM cadastro.eventos WHERE codigo=%s", (settings.evento_codigo,)
        ).fetchone()
        tentativa = atual(c, evento["id"]) if evento else None
        resultado = {"tentativa": tentativa_publica(c, tentativa)}
        if not tentativa:
            return resultado
        if usuario["perfil"] == "master":
            banca = c.execute(
                """SELECT u.id,u.nome,u.login,v.id AS voto_id
                FROM operacao.bancas b JOIN operacao.usuarios u ON u.id=b.juiz_id
                LEFT JOIN operacao.votos v ON v.evento_id=b.evento_id AND v.tentativa_id=b.tentativa_id AND v.juiz_id=b.juiz_id
                WHERE b.evento_id=%s AND b.tentativa_id=%s ORDER BY u.nome,u.id""",
                (tentativa["evento_id"], tentativa["id"]),
            ).fetchall()
            resultado.update(
                total=len(banca),
                recebidos=sum(r["voto_id"] is not None for r in banca),
                pendentes=[
                    {"id": str(r["id"]), "nome": r["nome"], "login": r["login"]}
                    for r in banca
                    if r["voto_id"] is None
                ],
            )
        else:
            elegivel = c.execute(
                "SELECT 1 FROM operacao.bancas WHERE evento_id=%s AND tentativa_id=%s AND juiz_id=%s",
                (tentativa["evento_id"], tentativa["id"], usuario["id"]),
            ).fetchone()
            voto = c.execute(
                "SELECT id,nota,horario FROM operacao.votos WHERE evento_id=%s AND tentativa_id=%s AND juiz_id=%s",
                (tentativa["evento_id"], tentativa["id"], usuario["id"]),
            ).fetchone()
            resultado.update(
                elegivel=bool(elegivel),
                enviado=bool(voto),
                recibo=recibo(voto, tentativa["id"]) if voto else None,
            )
        return resultado


def grupos_evento(c, evento_id):
    return c.execute(
        """SELECT DISTINCT cat.id::text || ':' || s.sexo_confirmado AS chave,
        cat.id AS categoria_id,cat.codigo AS categoria,s.sexo_confirmado AS sexo,cat.ordem,
        cat.codigo || ' ' || s.sexo_confirmado AS rotulo,
        CASE s.sexo_confirmado WHEN 'Masculino' THEN 0 ELSE 1 END AS ordem_sexo
        FROM cadastro.inscricoes i JOIN cadastro.skatistas s ON s.id=i.skatista_id
        JOIN cadastro.categorias cat ON cat.evento_id=i.evento_id
        AND cat.id=i.categoria_base_id
        WHERE i.evento_id=%s ORDER BY cat.ordem,ordem_sexo""",
        (evento_id,),
    ).fetchall()


def filtro_publico(c, evento_id):
    row = c.execute(
        """SELECT filtro_categoria_id::text || ':' || filtro_sexo AS grupo,
        filtro_revisao::text AS revisao FROM operacao.controle_evento WHERE evento_id=%s""",
        (evento_id,),
    ).fetchone()
    return row or {"grupo": None, "revisao": "0"}


def publicar_filtro(settings, request, grupo):
    with write_connection(settings) as c:
        evento_id = bloquear_evento(c, settings)
        sessao(c, request, perfil="master", bloquear=True)
        escolhido = next(
            (g for g in grupos_evento(c, evento_id) if g["chave"] == grupo), None
        )
        if not escolhido:
            raise HTTPException(422, "Grupo não encontrado neste evento.")
        c.execute(
            """UPDATE operacao.controle_evento SET filtro_categoria_id=%s,
            filtro_sexo=%s,filtro_revisao=filtro_revisao+1 WHERE evento_id=%s""",
            (escolhido["categoria_id"], escolhido["sexo"], evento_id),
        )
        return {"filtro": filtro_publico(c, evento_id), "mensagem": "Filtro publicado."}


def ranking_publico(settings):
    with read_connection(settings) as c:
        c.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        evento = c.execute(
            "SELECT id FROM cadastro.eventos WHERE codigo=%s", (settings.evento_codigo,)
        ).fetchone()
        if not evento:
            return {
                "categorias": [],
                "grupos": [],
                "filtro": {"grupo": None, "revisao": "0"},
                "inscricoes": [],
                "pista": None,
                "dia": None,
                "voltas_concluidas_hoje": [],
            }
        categorias = c.execute(
            "SELECT codigo,ordem FROM cadastro.categorias WHERE evento_id=%s ORDER BY ordem",
            (evento["id"],),
        ).fetchall()
        grupos = grupos_evento(c, evento["id"])
        filtro = filtro_publico(c, evento["id"])
        dia = c.execute(
            "SELECT (clock_timestamp() AT TIME ZONE 'America/Sao_Paulo')::date AS dia"
        ).fetchone()["dia"]
        if filtro["grupo"] not in {grupo["chave"] for grupo in grupos}:
            filtro["grupo"] = grupos[0]["chave"] if grupos else None
        rows = c.execute(
            """SELECT i.id,i.numero_provisorio,s.nome,cat.codigo AS categoria,f.versao AS avatar_versao,
            cat.id::text || ':' || s.sexo_confirmado AS grupo,
            max(t.media) FILTER (WHERE t.volta=1) AS v1,
            max(t.media) FILTER (WHERE t.volta=2) AS v2
            FROM cadastro.inscricoes i JOIN cadastro.skatistas s ON s.id=i.skatista_id
            JOIN cadastro.categorias cat ON cat.id=i.categoria_base_id
            LEFT JOIN cadastro.fotos_skatistas f ON f.skatista_id=s.id
            LEFT JOIN operacao.tentativas t ON t.evento_id=i.evento_id AND t.inscricao_id=i.id AND t.estado='concluida' AND t.dia_volta=%s
            WHERE i.evento_id=%s GROUP BY i.id,i.numero_provisorio,s.nome,cat.codigo,cat.id,s.sexo_confirmado,f.versao""",
            (dia, evento["id"]),
        ).fetchall()
        concluidas_hoje = c.execute(
            """SELECT inscricao_id,volta FROM operacao.tentativas
            WHERE evento_id=%s AND estado='concluida'
            AND dia_volta=%s
            ORDER BY inscricao_id,volta""",
            (evento["id"], dia),
        ).fetchall()
        pista = tentativa_publica(c, atual(c, evento["id"]))
    inscricoes = []
    for grupo in grupos:
        atletas = [r for r in rows if r["grupo"] == grupo["chave"]]

        def melhor(r):
            medias = [v for v in [r["v1"], r["v2"]] if v is not None]
            return max(medias) if medias else Decimal(-1)

        atletas.sort(key=lambda r: (-melhor(r), r["numero_provisorio"]))
        for r in atletas:
            nf = (
                max(r["v1"], r["v2"])
                if r["v1"] is not None and r["v2"] is not None
                else None
            )
            inscricoes.append(
                {
                    "id": str(r["id"]),
                    "nome": r["nome"],
                    "numero_provisorio": r["numero_provisorio"],
                    "avatar_versao": r["avatar_versao"],
                    "categoria": r["categoria"],
                    "grupo": r["grupo"],
                    "v1": format(r["v1"], ".2f") if r["v1"] is not None else None,
                    "v2": format(r["v2"], ".2f") if r["v2"] is not None else None,
                    "nf": format(nf, ".2f") if nf is not None else None,
                    "posicao": next(
                        i + 1 for i, a in enumerate(atletas) if melhor(a) == melhor(r)
                    )
                    if melhor(r) >= 0
                    else None,
                }
            )
    return {
        "categorias": categorias,
        "grupos": [
            {
                k: str(v) if k == "categoria_id" else v
                for k, v in g.items()
                if k not in {"ordem_sexo"}
            }
            for g in grupos
        ],
        "filtro": filtro,
        "inscricoes": inscricoes,
        "pista": pista,
        "dia": dia,
        "voltas_concluidas_hoje": concluidas_hoje,
    }
