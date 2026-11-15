# Responsividade do terminal e workflow

Entrega local de 2026-11-14, na branch `fix/terminal-performance`. Esta mudança trata custos identificados no estudo local; não comprova que o episódio de travamento ao criar/publicar uma página foi reproduzido ou resolvido.

## Comportamento

O terminal visível mantém uma consulta por vez e a pausa ociosa de 800 ms. Entrada e resize confirmados acordam o poller, sem reenviar mutações. Wakeups são agrupados e respeitam um intervalo mínimo de 100 ms entre inícios de captura. Trocar painel, sair da cena ativa ou fechar o detalhe cancela as consultas; uma nova tarefa aguarda a anterior terminar antes de capturar novamente. Isso preserva a arquitetura RPC por operação e limita a frequência adicional durante digitação.

A grade continua limitada a seis terminais por página, com pausa de três segundos por tile. Os inícios são distribuídos em offsets de 80 ms, e a consulta fica pausada fora da cena ativa. Isso reduz a concentração inicial de capturas, sem garantir que toda rajada possível de replay desapareça. Snapshots distintos ainda reconstroem o viewport ANSI completo no MainActor.

Snapshots, prontidão e erros iguais não são publicados novamente. No quadro, o polling automático usa um guard privado, sem publicar início/fim de carregamento a cada ciclo. Com conteúdo e workflow inalterados e sem erro, esse refresh não emite `objectWillChange`; atualização manual e primeira carga continuam apresentando carregamento.

O armazenamento de inbox, comentários, vínculos de PR e métricas roda em actor próprio. Uma fila ordena a operação e sua publicação antes da seguinte; init não lê disco. A inicialização carrega a inbox mesmo se a primeira consulta ao motor falhar. JSON inválido permanece preservado, e comentário confirmado continua reconhecido se sua releitura falhar. As ações async preservam rascunhos e confirmações durante espera.

O registro local de uma entrada confirmada tem uma fila separada do envio PTY: disco lento não segura a próxima tecla. Esse recorder permanece vivo quando o detalhe fecha durante um envio, sem reter o modelo da tela. Não há retry automático de entrada incerta e não há alteração nas aprovações dos provedores.

O deslocamento de I/O restringe-se ao workflow. Persistência de navegação, cadastro de projetos e salvamento manual de exportações não foram migrados nesta entrega.

## Validação

Os testes novos verificam wake de um poller ocioso sem esperar seu intervalo, agrupamento durante consulta em voo, cancelamento e substituição sem sobreposição, estados inalterados sem publicação, recuperação de erro, envio PTY durante bookkeeping suspenso, entrega após liberação do detalhe, I/O fora do MainActor, publicação em ordem e preservação de dados corrompidos e comentários já inseridos.

O renderer offscreen injeta `scenePhase = .active` no fixture para que a ausência de uma cena nativa não seja confundida com um terminal indisponível. Isso não valida transições de foco da janela real.

O microbenchmark do scheduler compara um reconhecimento sintético 25 ms após a primeira captura, mantendo a política ociosa de 800 ms. Sem wake, cinco amostras tiveram mediana de 822,75 ms de espera; com wake, dez tiveram mediana de 77,14 ms. Isso mede somente a espera do scheduler: exclui RPC, PTY, execução do provedor, parsing/desenho e teclado até pixels. O intervalo mínimo continua sendo 100 ms entre inícios de captura. Amostras pequenas e timers sujeitos ao host não sustentam um percentil estável de UX. [Dados completos](../scripts/evidence/benchmark-terminal-polling.json).

Reprodução sem provedores nem dados de usuário:

```sh
mkdir -p .build/performance-study
swiftc -parse-as-library -swift-version 6 -O Sources/TramaCore/TerminalSnapshotPoller.swift scripts/benchmark-terminal-polling.swift -o .build/performance-study/benchmark-polling
.build/performance-study/benchmark-polling .build/performance-study/polling-wake.json
```

Validação final com Apple Swift 6.1.2, macOS arm64:

- `swift build`: passou.
- `swift build --configuration release --jobs 2`: passou.
- `CARGO_BUILD_JOBS=2 ./scripts/cargo-local.sh build --locked --offline --release --manifest-path Engine/Cargo.toml --target-dir /Users/luizamaral/trama/Engine/target`: passou, sem alteração de código Rust ou pin.
- `TRAMA_TEST_ENGINE_PATH=/Users/luizamaral/trama/Engine/target/release/trama-engine swift test`: 154 testes passaram, incluindo integração com o motor compilado e processos controlados; nenhuma tarefa paga.
- `git diff --check`: passou; revisão independente sem bloqueadores restantes.
- `CARGO_BUILD_JOBS=2 ./scripts/package-app.sh --release`: bundle local atualizado em `.build/Trama.app`, com assinatura ad hoc verificada. O aplicativo aberto não foi encerrado ou reiniciado; é necessário reabri-lo para carregar a nova versão.
- Renderer isolado: sete PNGs e asserção de seis snapshots na grade passaram. Inspecionadas composição da grade e do detalhe. Como na validação anterior, a captura offscreen deixa a região de desenho do SwiftTerm vazia; não valida pixels do terminal ou interação. A grade enviou apenas snapshots e listagem durante a asserção.

Na primeira execução, o fixture de releitura substituía o arquivo por um diretório e não produziu a falha esperada neste ambiente. Foi corrigido para injetar JSON inválido depois da inserção confirmada. Outra execução mostrou o teste de wake excedendo o limiar de um segundo em 6 ms durante inicialização concorrente de suites AppKit. O teste usa intervalo ocioso de 30 segundos e agora distingue seu despertar com limiar de cinco segundos; não impõe meta de latência de UI. A suite final passou após esses ajustes.

Os logs locais ficam em `.build/performance-study/` e podem ser removidos pela limpeza de build.

## Limites

A latência entre teclado e pixels, o desenho de um e seis terminais sob saída intensa e o ciclo real de criar/publicar uma página ainda precisam de medição interativa. Testes controlados não exercitam provedores autenticados ou rede e não iniciam tarefas pagas. Não foi alterado o pin do motor Rust, nem foram encerrados processos ou liberada memória de outros aplicativos. A concorrência de memória observada no Mac continua sendo um fator externo ao Trama.
