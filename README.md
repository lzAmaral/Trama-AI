# Trama

**Seus projetos e agentes, em um só lugar.**

App nativo para macOS em SwiftUI, com terminal e motor Rust para executar CLIs de agentes em projetos locais.

## Estado atual

O quadro usa sessões reais por padrão: criar tarefas, acompanhar estados, enviar entrada ao terminal, encerrar e recuperar sessões interrompidas. Há filtros por projeto/sessão, busca, lista, histórico, descoberta de skills, worktrees, diff e merge confirmado. O modo **Demonstração** continua separado e identificado.

A interface usa superfícies grafite, tipografia monoespaçada e acentos verdes. O terminal é renderizado pelo SwiftTerm; o motor reutiliza a biblioteca Rust do Octo fixada em uma revisão. Veja [arquitetura e limites](docs/ENGINE_INTEGRATION.md).

Esta é uma versão de desenvolvimento. O fluxo de terminal foi testado com shell real e Git em diretórios temporários. Execução autenticada de cada provedor, revisão visual e distribuição notarizada ainda precisam de validação. Detectar um CLI não confirma login ou compatibilidade de sua versão.

## Executar

Requisitos: macOS 14+, Swift 6 e Rust compatível com o lockfile (validado com Swift 6.1.2 e Rust 1.99.1). O primeiro build baixa dependências.

```sh
git clone https://github.com/lzAmaral/Trama-AI.git
cd Trama-AI
./scripts/build-engine.sh
swift run Trama
```

O repositório privado requer acesso. Para gerar um aplicativo local:

```sh
./scripts/package-app.sh
open .build/Trama.app
```

O bundle tem assinatura ad hoc para desenvolvimento, sem Developer ID ou notarização. Detalhes em [PACKAGING.md](docs/PACKAGING.md). O script também aceita `--release`.

Cadastre uma pasta, escolha **Nova tarefa** e selecione um provedor instalado ou **terminal**. Os CLIs precisam estar no PATH herdado pelo aplicativo; abrir pelo Finder pode resultar em um PATH diferente do terminal. Login permanece no CLI. A execução pode modificar arquivos e, para agentes de IA, enviar dados ao provedor. Fechar a janela **não encerra** os agentes; use o controle de encerramento na tarefa.

## Dados e controles

Projetos ficam em `~/Library/Application Support/Trama/projects.json`; sessões e logs do motor, em `~/Library/Application Support/Trama/Engine`. O cadastro de pastas não altera seu conteúdo. Um arquivo de projetos inválido bloqueia gravações para preservar os dados. Execute uma instância do app por vez; as mutações do motor têm lock, mas o cadastro de projetos ainda não coordena múltiplas instâncias.

A ação **Motor** detecta provedores sem acessar credenciais ou rede. A consulta de consumo só ocorre ao escolher um provedor e clicar **Consultar agora**, usando o adaptador upstream. Ela pode ler credenciais locais e consultar o serviço correspondente; não roda em segundo plano. Não foi validada com contas reais nesta entrega.

As aprovações do CLI permanecem no terminal. Merge exige worktree isolada, agente encerrado, revisão das alterações e confirmação. O aplicativo não ativa bypass de permissões, acesso remoto ou atualizações automáticas.

## Validar

```sh
./scripts/build-engine.sh
./scripts/cargo-local.sh test --locked --manifest-path Engine/Cargo.toml
TRAMA_TEST_ENGINE_PATH="$PWD/Engine/target/debug/trama-engine" swift test
git diff --check
```

Os testes cobrem persistência, erros e limites do transporte, cancelamento, lifecycle real de shell e operações Git isoladas. Não executam tarefas de IA pagas ou consultas autenticadas. A compilação e os testes não substituem a revisão visual.

## Desenvolvimento

- `Sources/TramaApp`: SwiftUI, estado de apresentação e terminal.
- `Sources/TramaCore`: persistência, modelos e cliente JSON do motor.
- `Engine`: adaptador Rust, dependência fixada e testes de lifecycle.
- `Tests/TramaCoreTests`: contratos Swift e integração com o binário real.
- `scripts`: build e empacotamento local.

O integrador define contratos, distribui arquivos entre agentes e controla Git; outro agente revisa o comportamento antes da integração. Consulte [AGENTS.md](AGENTS.md), [engenharia](docs/ENGINEERING.md), [tarefas](docs/TASKS.md), [roadmap](docs/ROADMAP.md) e [segurança](docs/SECURITY.md).

## Referências e dependências

[Octo](https://github.com/lucasmarujo/octo) fornece o motor Rust reutilizado; [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) fornece o terminal nativo. Revisões e versões ficam nos manifests e lockfiles; avisos em [ThirdPartyNotices](ThirdPartyNotices/README.md). [Maestrum](https://github.com/gabrielgreco1/maestrum) é uma referência de produto, sem código incorporado.
