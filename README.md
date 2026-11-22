# Iago System ACSN · Login e votação local

Homologação: http://127.0.0.1:8095/ . FastAPI/PostgreSQL, ranking público, contas de juiz e votação persistida. Credenciamento permanece somente leitura e exige master. As 12 inscrições e quatro marcas PNG foram preservadas. Sem deploy ou vínculo remoto nesta entrega.

## Abrir e operar

Com Docker Desktop aberto, execute `C:\dev_yc\versionador_ambientes\ambiente_homologacao\porta8095.bat` ou `iniciar_iago_system.bat` na pasta do projeto. O iniciador abre/reaproveita a instância sem encerrar outros programas. O servidor antigo deste projeto na porta 8000 foi encerrado para evitar as rotas anteriores sem autenticação.

1. Clique **Entrar** no ranking. Conta inicial local: login `admin`, senha `admin`, conforme solicitado. Ela já foi criada, com troca obrigatória; os testes não trocaram essa senha na base real.
2. Em **Alterar senha**, informe atual, nova e confirmação. Use 12 a 128 caracteres, com maiúscula, minúscula, número e símbolo. Operações protegidas ficam bloqueadas até a troca.
3. Abra **Menu → Administração de usuários**. Cadastre cada juiz com nome, login único e senha inicial forte. O juiz também precisa trocar sua senha no primeiro acesso. A tela permite ativar/desativar sem devolver senha ou hash.
4. No ranking do master, escolha categoria, competidor e V1 ou V2. V2 pode vir antes da V1. **Colocar na pista** é opcional; **Liberar votação** abre diretamente ou libera a chamada correspondente.
5. A liberação congela todos os juízes ativos naquele momento. Não abre sem juiz. Existe uma única tentativa em pista por evento. Novas contas e alterações de atividade valem para as próximas bancas.
6. Cada juiz vê participante e volta, mesmo se estiver olhando outra categoria. Digita nota de 0 a 100, até duas casas, com ponto ou vírgula, e confirma o envio. Zero é válido; master não vota.
7. Enquanto falta alguém, não há média parcial nem votos individuais no ranking. Apenas o master vê total, recebidos e pendentes. O juiz vê somente o estado e recibo do próprio envio.
8. O último voto publica a média na mesma transação do fechamento. 70,00 + 74,25 + 76,00 produz 73,42. Com uma média há posição provisória; NF aparece depois de ambas e usa a maior. Empates compartilham posição.
9. Se um juiz ficar indisponível, cancele com motivo, ajuste as contas e abra outra tentativa. Votos cancelados permanecem internos, sem média pública. Resultados concluídos não são reabertos.
10. **Alterar senha** renova a sessão atual e revoga as demais. **Sair** invalida a sessão no servidor. Recarregar preserva pista e resultados no banco.

Abas do mesmo perfil do navegador compartilham cookies. Para master e juízes separados no mesmo computador, use perfis ou navegadores distintos. Acesso por celulares em redes diferentes depende de uma implantação HTTPS futura; o ambiente atual mantém loopback.

## Comandos Windows CMD

Servidor já está configurado e iniciado nesta entrega. Para reiniciar quando a porta estiver livre:

```bat
cd /d C:\dev_yc\versionador_ambientes\ambiente_homologacao\iago_system
npx --yes supabase@3.2.0 db start --network-id iago_system_loopback
.venv\Scripts\python -m uvicorn backend.app:app --host 127.0.0.1 --port 8095 --no-access-log --no-proxy-headers
```

Instalação/atualização local reproduzível, preservando o `.env` privado existente:

```bat
cd /d C:\dev_yc\versionador_ambientes\ambiente_homologacao\iago_system
.venv\Scripts\python -m pip install -r requirements-dev.txt
npx --yes supabase@3.2.0 migration up
.venv\Scripts\python -m scripts.configurar_roles
.venv\Scripts\python -m scripts.bootstrap_admin
```

O bootstrap pede a senha por entrada oculta. No primeiro cadastro local foi usado `admin`. Reexecutar nunca redefine conta existente. Exige conexão administrativa em loopback e não cria sessão. Nenhuma conta é criada automaticamente ao iniciar a API.

Migrações incrementais aplicadas: `20261120000100_login_votacao.sql` e `20261120000200_bloqueio_pista.sql`. A migração inicial de cadastro permanece preservada. Nenhum reset foi executado.

Para parar somente esta instância preservando dados:

```bat
npx --yes supabase@3.2.0 stop --project-id iago_system
```

## API e organização

- `GET /api/ranking`: catálogo compatível, com `v1`, `v2`, `nf`, `posicao` e `pista`. Médias são strings de duas casas ou null. Não inclui escola, nascimento, sexo, nomes de juízes ou votos individuais.
- `GET /api/skatistas`: contrato anterior do credenciamento, exclusivo do master; HTML e acesso direto a index.html também protegidos.
- `GET /api/sessao`; `POST /api/auth/login`, `/api/auth/senha`, `/api/auth/logout`: autenticação. Login recebe login/senha; troca recebe atual/nova/confirmacao.
- `GET/POST /api/usuarios`; `PATCH /api/usuarios/{id}`: master lista/cria juiz com nome/login/senha e altera ativo.
- `GET /api/competicao/estado`: progresso e pendentes somente ao master; elegibilidade e envio próprio ao juiz.
- `POST /api/competicao/chamar` e `/api/competicao/abrir`: master envia inscricao_id e volta (1 ou 2).
- `POST /api/competicao/{id}/cancelar`: master informa motivo.
- `POST /api/competicao/{id}/votos`: juiz envia nota como string decimal. Repetição da mesma nota recupera o recibo original, inclusive após fechamento. Valor diferente dá conflito. Tentativa cancelada ou antiga sem recibo não aceita novo voto.

Mutações exigem Origin da mesma origem; as autenticadas exigem também X-CSRF-Token da própria sessão. Perfil, atividade, validade e troca obrigatória são verificados no servidor. Os controles da tela não autorizam ações.

Backend separa configuração, conexão, segurança, serviços e rotas. Frontend separa configuração, HTTP, sessão, renderização e eventos. Simulação, seletor de perfil e reset foram removidos. Atualização a cada dois segundos, sem sobreposição por consulta, retomada ao voltar à aba e sinalização de desconexão. O campo digitado permanece na mesma tentativa; mudança de tentativa limpa o formulário e impede resposta antiga de confirmar outra nota. Sem localStorage.

## Segurança e banco

Senhas Argon2id: 19 MiB, duas iterações, paralelismo 1. Sessões opacas de 256 bits, armazenadas por hash, com expiração padrão de oito horas. Cookie HttpOnly, SameSite=Strict e Secure quando servido em HTTPS. Troca revoga outras sessões e renova a atual. Cinco falhas em 15 minutos bloqueiam novas tentativas daquele login/origem até a janela expirar; respostas de autenticação são genéricas.

Schemas privados, sem acesso a PUBLIC, anon ou authenticated. Runtime lê cadastro e escreve somente nas tabelas operacionais autorizadas; não altera/apaga votos e bancas. Importador permanece separado. A conta administrativa só é usada em migração, provisionamento, bootstrap e testes isolados.

Abertura, voto e cancelamento bloqueiam a linha operacional do evento antes de conta/tentativa. Voto único por tentativa/juiz e FK para a banca congelada. Média NUMERIC/Decimal arredondada somente na publicação atômica do último voto. Chaves e índices impedem duas pistas abertas e dois resultados para a mesma volta.

Somente frontend é publicado. CSV, `.env`, dumps e logs continuam privados/ignorados. Validação não ecoa senhas; o iniciador mantém log privado sem access log. Sem CORS ou cache. Host, origem e rede HTTP continuam locais. A publicação Docker do PostgreSQL mantém a configuração anterior e deve ser revista antes de ampliar acesso ou publicar.

## Testes reais e pendências

```bat
cd /d C:\dev_yc\versionador_ambientes\ambiente_homologacao\iago_system
.venv\Scripts\python -m pytest -q --tb=short
.venv\Scripts\python -m ruff check backend scripts tests
.venv\Scripts\python -m ruff format --check backend scripts tests
.venv\Scripts\python -m compileall -q backend scripts tests
npx --yes prettier --check "frontend/**/*.html" "frontend/**/*.css" "frontend/**/*.js"
for /r frontend\js %f in (*.js) do @node --check "%f"
```

Em .bat, use %%f. O pytest cria/remove somente bancos exclusivos `iago_test_<uuid>` com dados fictícios. Requer conta administrativa local com CREATEDB, Docker e Edge para o navegador. O teste visual inicia servidor temporário em porta livre com o banco de teste. Capturas fictícias: `work/capturas-votacao/`, ignoradas pelo Git.

**28 testes aprovados.** Cobrem autenticação, troca, revogação, logout, expiração, CSRF, perfis, importação/preservação, bancas de 1/2/3/4, congelamento, decimal/zero, V2 antes de V1, empate, aberturas concorrentes, dois últimos votos simultâneos, cancelamento concorrente e recibo idempotente. Navegador: master, três juízes e público independentes; cadastro/troca pela tela, atualização sem reload, destaque da linha/volta, perda/retorno de conexão, campo preservado, persistência após reload, menu e credenciamento. Sem erros JavaScript; 360/1440 px sem rolagem horizontal. Capturas inspecionadas e ajuste de legibilidade mobile aplicado.

Sintaxe, Ruff e Prettier aprovados. Há um aviso de descontinuação do adaptador httpx do Starlette, sem falha. Credenciais técnicas foram renovadas no `.env` privado. Integridade do cadastro conferida antes/depois: 12 inscrições idênticas e quatro PNGs preservados byte a byte. Base real contém somente o master inicial, sem juízes, tentativas ou votos fictícios. HTTP 8095 validado: ranking público, APIs privadas protegidas, CSV/.env 404 e entrada inicial com troca obrigatória.

Não existe repositório Git nesta pasta; revisão feita pelo snapshot e árvore final. Aguardando aceite visual/operacional. Rede externa, HTTPS, deploy e regulamento oficial ficam para a etapa seguinte. Admin/admin é exclusivo desta homologação e exige troca antes de operar.

Referências: [OWASP Password Storage](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html), [OWASP Session Management](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html).

## Migração de homologação para o Supabase

Use uma cópia do projeto para testar com dados fictícios. Em seguida, aplique os
arquivos do patch sobre a versão conferida do projeto e instale as dependências
atualizadas. Guarde uma cópia privada do código anterior e do .env para retorno.

1. Com a configuração local preservada, instale `requirements-dev.txt` e execute
   `python -m pytest -q --tb=short` com um PostgreSQL de teste acessível, usando
   as três URLs locais indicadas no .env.example. A suíte cria bancos descartáveis.
2. Confira o acesso a `ADMIN_DATABASE_URL` e `SUPABASE_MIGRATION_URL`, a
   disponibilidade de `pg_dump` e `pg_restore` compatíveis com o servidor, e o
   projeto `yoewqaatkoltozppohxu`. Suspenda as gravações da homologação.
3. Execute `python -m scripts.migrar_supabase --executar` na raiz do projeto.
   O backup fica em `dados_privados/`. Guarde a saída agregada, confira as
   divergências de categoria e as exceções de tentativas concluídas sem voto.
   A cópia reconcilia os registros pelos IDs e valores, incluindo hashes,
   preserva as datas originais e exclui sessões e falhas de login da transferência.
   A execução usa SQL versionado via PostgreSQL direto ou Session pooler, com TLS.
   Se for adotar a CLI Supabase mais tarde, alinhe a tabela oficial de histórico
   com as versões efetivamente aplicadas antes de usar `db push`.
4. Configure em privado `SUPABASE_DATABASE_URL` e `SUPABASE_IMPORT_DATABASE_URL`
   com senhas distintas e as contas `iago_runtime` e `iago_importador`.
   No Session pooler, use o usuário no formato `role.referencia-do-projeto`.
   Execute `python -m scripts.configurar_roles --supabase`.
5. Selecione `IAGO_BANCO=supabase` e inicie a homologação na porta 8095.
   Compare os rankings por dia e por grupo, entre com contas Master e juiz
   existentes, valide as permissões e consulte as notas históricas por dia com
   `GET /api/notas?dia=AAAA-MM-DD` como Master. Faça testes que criam cadastros
   e votos em ambiente isolado com dados fictícios. Libere gravações reais
   após a validação.

A role de execução pode inserir skatistas e inscrições e operar as tabelas de
autenticação e competição. A atualização direta de cadastros e o importador
inicial continuam separados. As ações da API de cadastro exigem Master e CSRF.

Para retornar ao PostgreSQL de origem, suspenda gravações no destino. Se houve
gravações desde a troca, faça backup privado do destino e reconcilie as alterações
por IDs, horários, votos, vínculos e estado antes de reabrir a operação. Se houve
novos resultados para a mesma volta em dias diferentes, a estrutura antiga da
origem exige uma atualização compatível antes de receber esses resultados.
Se a origem permaneceu com o esquema anterior e o destino ainda estava em
validação sem novas gravações, retome com o código anterior e o .env local salvo.

