# Trama

**Seus projetos e agentes, em um só lugar.**

Um app nativo para macOS, desenvolvido em Swift.

## Estado atual

Primeira base de desenvolvimento em SwiftUI: cadastro de pastas locais como projetos, armazenamento local e uma visão demonstrativa de agentes e atividade. Os agentes exibidos são fictícios: **esta versão não executa agentes, comandos ou APIs de IA**.

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

## Validar

```sh
swift build
swift test
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

Não há dependências de terceiros nesta base.

## Desenvolvimento com agentes

O integrador define contratos e tarefas; agentes implementam partes independentes; outro agente revisa antes da integração. Em checkout compartilhado, somente o integrador controla Git.

Consulte [AGENTS.md](AGENTS.md), os [critérios de engenharia](docs/ENGINEERING.md) e o [roadmap](docs/ROADMAP.md). O próximo marco integra um primeiro CLI com estados reais, cancelamento e tratamento de erros.

