# Evidências da interface nativa baseada no Octo

Entrega local de 2026-11-14, branch `feat/octo-native-workspace`. O checkout já continha a entrega visual anterior sem commit; esta entrega evolui essas alterações. Escopo e origem: [OCTO_NATIVE_PARITY.md](OCTO_NATIVE_PARITY.md).

## Ambiente e checks executados

- macOS 26.6.2 (25G83), Apple Silicon / arm64; Apple Swift 6.1.2, modo Swift 6, destino mínimo macOS 14.
- `swift build`: passou após a integração e correções.
- `swift test`: passou. Runner reportou 137 testes em 15,560 s; três testes de integração opt-in foram ignorados: `swiftCommunicatesWithTheCompiledRustEngine`, `swiftControlsARealShellAcrossRequestProcesses` e `compiledEngineReviewAndCancellationLeaveTheHolderAlive`.
- `git diff --check`: passou.
- `scripts/package-app.sh`: build Rust `--locked`, build Swift, recursos e assinatura ad hoc verificados; bundle principal `.build/Trama.app` atualizado.
- Nenhum arquivo do motor, pin, lockfile ou integração de provedor foi alterado; a suíte Cargo não foi repetida nesta entrega.

Os testes novos exercitam seleção de sessão com abas em outros projetos, sessão vazia/removida, restauração da sessão e do modo Grade, leitura do JSON antigo sem o novo campo, preservação de rascunhos e ausência de operações no motor ao navegar. A regressão encontrada na revisão ganhou um teste específico: trocar sessões antes do primeiro poll, incluindo primeira leitura inválida, não remove nem persiste a remoção de abas restauradas.

## Renderização reproduzível e isolada

```sh
./scripts/render-workspace-preview.sh
```

O script compila um harness que importa as views reais do aplicativo, injeta repositórios temporários e um processo Python de RPC fictício, e desenha `NSHostingView` em janelas não apresentadas no desktop. O aplicativo e o motor reais do usuário não são iniciados nem controlados. O fake rejeita início de agentes, entrada e operações externas; apenas listagem, inspeção, skills fictícias, snapshots fictícios e resize local do detalhe são aceitos. O harness não consulta contas, rede ou credenciais.

Arquivos em `.build/octo-native-previews/`:

- `octo-native-board.png`: quadro carregado em 1440 × 900 pt, sessões expandidas, estados e atividade de oito registros fictícios.
- `octo-native-compact.png`: composição em 820 × 560 pt, com rolagem horizontal do quadro.
- `octo-native-list.png`: tabela de agentes agrupada por projeto, alinhada ao topo.
- `octo-native-grid.png`: composição da grade com seis tiles e paginação.
- `octo-native-agent.png`: layout de terminal, compositor e painel lateral de contexto.
- `octo-native-empty.png`: primeira execução sem projetos cadastrados em store isolado.
- `octo-native-storage-error.png`: falha de leitura de JSON temporário; o harness também confirma que seus bytes inválidos permanecem intactos.

A asserção da grade exige exatamente seis chamadas de snapshot no fixture de oito agentes e permite apenas `list` e `snapshot` durante essa etapa. A execução passou e registrou seis snapshots, sem input, resize, start ou resume. Consultas do detalhe são posteriores e separadas dessa asserção.

As capturas foram inspecionadas para composição, alinhamento, legibilidade e estados vazio/erro. Foram corrigidos a centralização indevida da lista, a orientação antiga para escolher projeto na lateral, a quebra do texto do estado na tabela e indicadores duplicados nos menus.

As regiões de desenho do SwiftTerm ficaram vazias na captura offscreen desta sessão. Portanto os PNGs da grade e do detalhe comprovam somente composição; não validam a renderização da saída do terminal. A comunicação de snapshots foi exercitada com dados fictícios, e o terminal nativo existente continua exigindo a revisão interativa descrita abaixo.

## Revisão independente

Um agente sem autoria revisou os diffs dos autores e os contratos de navegação. Os três P2 encontrados foram corrigidos e reverificados:

1. Selecionar sessão antes do primeiro snapshot válido podia podar abas restauradas: guarda de carregamento adicionada e teste de falha aprovado.
2. Sessão local do compositor podia divergir da lateral: removida a segunda fonte de estado e exibido o destino da tarefa.
3. Vários cartões de consumo podiam ultrapassar o painel: lista rolável limitada, mantendo o cabeçalho e o rodapé.

Também foram conferidos cancelamento e limite da grade, preservação do último snapshot em erro, callback de consumo apenas após consulta manual e ausência de alterações em aprovações, pins e RPCs. A revisão final verificou a injeção de fixtures sem alterar os defaults de produção. A recomendação de exigir snapshots positivos no harness foi aplicada como igualdade com seis neste fixture.

## Critérios ainda abertos

O controle do computador falhou nesta sessão com `Sky Computer Use native pipe startup failed`; não foi uma rejeição de aprovação. Houve duas tentativas. Por isso não foram validados a interação no bundle atual, menus por teclado, foco, VoiceOver, desenho PTY real, desempenho com saída intensa ou paginação manual da grade. A revisão parcial de 2026-11-08 não substitui essa revisão após a mudança estrutural.

Não foram iniciadas tarefas de IA pagas, consultas autenticadas de consumo, exposição remota, certificados, notarização ou publicação. Paridade completa com o Octo atual não está anunciada. O limite de identidade das leituras de snapshot e as diferenças funcionais permanecem explícitos no mapeamento de paridade.

A rodada seguinte corrigiu a adaptação a janelas menores e acrescentou uma matriz de dimensões: [validação de responsividade](RESPONSIVE_UI_VALIDATION.md).
