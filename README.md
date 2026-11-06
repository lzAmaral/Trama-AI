# Trama

**Seus projetos e agentes, em um só lugar.**

Um app nativo para macOS, desenvolvido em Swift.

## Estado atual

Primeira base de desenvolvimento em SwiftUI: cadastro de pastas locais como projetos, armazenamento local e uma visão demonstrativa de agentes e atividade. Os agentes exibidos são fictícios: **esta versão não executa agentes nem chama APIs de IA**. A ação Motor executa apenas o processo auxiliar de inspeção local.

A interface segue uma direção de terminal: fonte monoespaçada, superfícies grafite, verde discreto, um quadro de agentes por status, modo lista e detalhes com atividade em formato de log. Os controles continuam nativos. Veja a [direção visual](docs/DESIGN.md).

## Executar

Requisitos: macOS 14 ou superior e toolchain Swift 6.0 ou superior (Xcode ou Command Line Tools compatíveis). Desenvolvimento inicial validado com Swift 6.1.2.

```sh
git clone https://github.com/lzAmaral/trama.git
cd trama
swift run Trama
```

O repositório está privado; o clone requer acesso. O pacote produz um executável de desenvolvimento, ainda sem bundle `.app`, assinatura ou instalador. Abra `Package.swift` no Xcode caso prefira trabalhar pela IDE.

Execute apenas uma instância do Trama por vez nesta versão: o armazenamento ainda não coordena gravações de processos simultâneos.

O cadastro armazena apenas nome, identificador e caminho das pastas em `~/Library/Application Support/Trama/projects.json`. Não modifica os arquivos dos projetos. Um erro de leitura é apresentado e bloqueia novas gravações até que o arquivo seja recuperado; o arquivo inválido não é substituído silenciosamente.

## Compilar o motor local

A interface usa SwiftUI e o motor reutiliza uma biblioteca Rust fixada. Requisitos adicionais: Rust 1.88+ e acesso à rede no primeiro build para baixar dependências. A instalação local de desenvolvimento usada nesta máquina fica em `.build/toolchains`, sem alterar o PATH global.

```sh
./scripts/build-engine.sh
swift run Trama
```

Abra **Motor** para verificar os provedores detectados. Detectado significa que o executável está disponível no PATH herdado; não confirma login. O diagnóstico não inicia agentes e usa armazenamento separado em `~/Library/Application Support/Trama/Engine`.

A arquitetura e as funcionalidades ainda por conectar estão em [ENGINE_INTEGRATION.md](docs/ENGINE_INTEGRATION.md).

## Validar

```sh
swift build
swift test
./scripts/cargo-local.sh test --locked --manifest-path Engine/Cargo.toml
TRAMA_TEST_ENGINE_PATH="$PWD/Engine/target/debug/trama-engine" swift test --filter EngineIntegrationTests
git diff --check
```

Os testes usam diretórios temporários e verificam persistência, corrupção de dados, versão de armazenamento incompatível e falhas de gravação. A interface também requer verificação manual: compilação não comprova comportamento visual.

## Visão geral de agentes

O quadro inicial reúne **Precisa de você**, **Em andamento**, **Concluído** e **Disponível**. Filtro de projeto, busca, alternância Quadro/Lista e detalhes funcionam sobre dados demonstrativos. A demonstração pode ser explorada sem cadastrar uma pasta; esses projetos fictícios não são salvos. Desligar Demonstração mostra o estado sem agentes conectados.

Não há criação de sessões reais, aprovação, diff, merge ou medição de cotas nesta versão. Os requisitos para essas integrações estão em [Segurança](docs/SECURITY.md).

## Estrutura

- `Sources/TramaApp`: interface SwiftUI e estado de apresentação.
- `Sources/TramaCore`: modelos e persistência, independentes da interface.
- `Tests/TramaCoreTests`: testes automatizados do núcleo.
- `.github/workflows/ci.yml`: build e testes em macOS.

O pacote Swift não tem dependências externas. O motor Rust possui dependências fixadas por revisão e `Engine/Cargo.lock`; os avisos estão em [ThirdPartyNotices](ThirdPartyNotices/README.md).

## Desenvolvimento com agentes

O integrador define contratos e tarefas; agentes implementam partes independentes; outro agente revisa antes da integração. Em checkout compartilhado, somente o integrador controla Git.

Consulte [AGENTS.md](AGENTS.md), os [critérios de engenharia](docs/ENGINEERING.md) o [roadmap](docs/ROADMAP.md) e as [tarefas com dependências](docs/TASKS.md). O marco ativo conecta o motor Rust à interface; a próxima entrega valida uma sessão real com saída, entrada e encerramento.

## Referências

- [Octo](https://github.com/lucasmarujo/octo): organização de agentes e projetos em uma janela.
- [Maestrum](https://github.com/gabrielgreco1/maestrum): acompanhamento e orquestração em um app nativo de macOS.

O motor utiliza a biblioteca Rust do Octo como dependência. O Maestrum permanece apenas como referência de estudo.
