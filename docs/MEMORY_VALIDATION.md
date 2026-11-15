# Memória: medições e mudanças locais

Estudo de 2026-11-15, na branch `perf/memory-budget`, em macOS arm64. Os benchmarks usam processos novos, executáveis fixados por SHA-256, projetos e armazenamento temporários e somente shells controlados. Não iniciam provedores de IA, consultam consumo ou acessam o armazenamento real do Trama. As medições anteriores do aplicativo aberto não são o baseline deste estudo.

## Motor e histórico

O benchmark `scripts/benchmark-engine-memory.py` usa seis shells, redimensiona um deles para 100×240 e produz 10.000 linhas (2.380.000 bytes antes da expansão do PTY). A leitura de histórico ocorre depois de encerrar esse shell e descarregar o log. Os binários anterior e candidato leem os mesmos dados, em ordem alternada, oito vezes cada. `/usr/bin/time -l` mede o pico de footprint e RSS de cada processo RPC; sua duração inclui a instrumentação e a criação do processo. Isso não mede o conjunto app + holders + CLIs.

| Leitura do histórico | Antes | Depois |
| --- | ---: | ---: |
| Mediana do pico de footprint | 47,25 MiB | 43,19 MiB |
| Mediana da duração da operação | 23,44 ms | 18,12 ms |

A repetição final mostrou redução de 4.259.840 bytes (**8,6%**) no pico de memória e 22,7% na duração, com respostas `text` e `truncated` idênticas. O primeiro comparativo mostrou 8,4% de redução de memória. [Amostras finais e hashes](../scripts/evidence/engine-memory-comparison-repeat.json).

O motor continua usando o replay ANSI upstream. A mudança extrai apenas as últimas linhas necessárias para a resposta de 64 KiB, evitando materializar todo o transcript e depois cortá-lo. O parser upstream ainda conserva até 5.000 linhas; a leitura de um arquivo de até 16 MiB não consome apenas 64 KiB de RAM. A origem do comportamento de extração está atribuída no código e a licença MIT já integra os avisos do projeto. O pin não mudou.

Testes diferenciais comparam a resposta ao comportamento anterior, usando a implementação upstream como referência. Incluem arquivo ausente, linhas vazias e espaços Unicode, ANSI, tela alternativa, resize, rotação, registro incompleto e cortes exatamente ao redor de 64 KiB ou dentro de caracteres UTF-8. Testes Python exercitam isolamento, início com resultado incerto, cleanup falho, divergência de conteúdo e encerramento do grupo transitório em timeout/sinal.

Não foi alterada a concorrência da listagem. Com seis sessões o pico mediano observado foi aproximadamente 1,3 MiB; esse estudo não justifica mudar os prazos para a hipótese de 64 sessões. Também não foi alterado o protocolo de snapshots: ele inclui histórico do upstream, mesmo com scrollback zero na apresentação SwiftTerm. Reduzir esse transporte exige outra avaliação de compatibilidade.

## Interface nativa

`scripts/benchmark-ui-memory.swift` conecta as views reais a um motor isolado. Cada cenário abre um processo novo e uma janela nativa de 1440×900 pontos, com seis shells. Cada shell recebe 40.000 linhas, totalizando 3.640.000 bytes por shell antes da expansão do PTY. O harness amostra `TASK_VM_INFO.phys_footprint` e CPU a cada 250 ms, solicita layout/desenho e confirma o marcador final tanto no RPC quanto no buffer de cada SwiftTerm exibido. A fase da cena é injetada para tornar o teste determinístico.

O baseline inclui lista, um terminal, grade de seis terminais e 20 ciclos de abertura/fechamento. A repetição independente em processos novos confirmou footprint após a carga de 39,28 / 39,41 / 39,07 MiB na lista e 58,67 / 58,34 / 58,86 MiB na grade de seis. [Baseline completo](../scripts/evidence/ui-memory-baseline.json) e [repetições](../scripts/evidence/ui-memory-baseline-repeat.json).

Nos 20 ciclos, as 20 views de terminal foram liberadas em até um segundo após fechar. O footprint após os ciclos ficou em aproximadamente 63 MiB, acima dos aproximadamente 39 MiB iniciais. As amostras após fechamento não cresceram continuamente; caches e alocações do AppKit/SwiftUI permanecem. Isso não demonstra ausência de vazamentos ou estabilidade durante horas de uso.

### Grade econômica

A grade passou a abrir duas prévias por página, com seletor para voltar a seis. Mudar a quantidade volta à primeira página, libera as prévias removidas e mantém todas as sessões em execução. A preferência dura enquanto a instância da área de trabalho existir; não altera preferências globais nem o formato persistido de navegação. Lista e quadro continuam disponíveis.

O teste da transição 6→2 revelou que `LazyVGrid` conservava uma view nativa removida, mesmo depois de ela sair da hierarquia exibida. A identidade do contêiner agora depende das identidades da página visível, descartando o contêiner anterior ao mudar densidade, página ou filtro. Atualizações de status das mesmas identidades não recriam a grade. A regressão verifica referências fracas depois de reduzir a densidade e depois de filtrar outro conjunto. Liberar views não obriga o alocador ou o sistema gráfico a devolver imediatamente toda a memória de seus caches.

Comparação final com o mesmo binário release da interface e o mesmo motor, em seis processos novos e ordem alternada:

| Prévias / execução | Mediana em repouso | Mediana após carga | Maior footprint amostrado |
| --- | ---: | ---: | ---: |
| 2 / 1 | 48,41 MiB | 49,94 MiB | 99,06 MiB |
| 6 / 1 | 55,39 MiB | 60,44 MiB | 114,30 MiB |
| 6 / 2 | 55,09 MiB | 60,66 MiB | 120,86 MiB |
| 2 / 2 | 48,38 MiB | 52,52 MiB | 103,64 MiB |
| 2 / 3 | 48,92 MiB | 50,47 MiB | 99,45 MiB |
| 6 / 3 | 55,24 MiB | 60,22 MiB | 115,36 MiB |

A mediana das três execuções após carga caiu de **60,44 para 50,47 MiB (16,5%)**. A mediana dos maiores valores amostrados nas fases comuns caiu de 115,36 para 99,45 MiB (13,8%). Todos os cenários confirmaram os marcadores nos dois ou seis buffers nativos esperados e encerraram seus shells privados. [Amostras, hashes e contagens](../scripts/evidence/ui-memory-density.json). São três execuções por configuração, sem estimativa de percentil estável. O processo medido é o harness que hospeda a interface real; os números não são um orçamento universal do aplicativo distribuído.

Depois das fases comparáveis, cada cenário de seis prévias também passou pela troca 6→2. Nas três execuções, as seis views anteriores foram liberadas em até dois segundos, não restou view removida retida e os dois novos terminais exibiram o marcador em seus buffers. Ao fim dessa fase, o footprint foi 54,74 / 54,74 / 54,28 MiB; durante a reconstrução houve picos transitórios amostrados de 99,55 a 100,88 MiB. Essa fase está separada no JSON e não entra na comparação de picos acima. Trocar a configuração não equivale a uma queda instantânea de RAM.

O teste de comportamento da grade verifica troca 2→6→2, mudança do conjunto filtrado, liberação das views removidas e ausência de abertura ou operações de controle de sessão nessas transições. O fixture AppKit não expôs a árvore de acessibilidade dos botões; cliques de paginação não fazem parte dessa cobertura automatizada.

## Reprodução e limites

Compilação do motor:

```sh
CARGO_BUILD_JOBS=2 ./scripts/cargo-local.sh build --release --locked --offline --manifest-path Engine/Cargo.toml
python3 scripts/benchmark-engine-memory.py --engine current=Engine/target/release/trama-engine --output .build/memory-study/engine-current.json
```

Para comparar duas versões, forneça `--engine baseline=CAMINHO --engine candidate=CAMINHO`. O script faz cópias privadas e confirma que todos os registros do home de teste estão encerrados antes de removê-lo. Falha de cleanup preserva o diretório para recuperação e não publica um relatório de sucesso.

O `--help` de `scripts/benchmark-ui-memory.py` contém a compilação do harness release com `-enable-testing`, necessária para acessar as views internas. Esse flag é usado nas duas variantes. `--modes` escolhe os cenários e `--repetitions` alterna sua ordem. As amostras da UI não incluem memória dos holders ou provedores; os máximos são **picos amostrados**, não o pico absoluto do processo. Não se deve somar máximos de processos medidos em momentos diferentes.

Janela visível e marcador no buffer não equivalem à inspeção dos pixels ou à medição de teclado até pixels. A revisão de VoiceOver, o piloto autenticado e a validação interativa sob carga continuam separados. Os resultados vêm de uma máquina e de cargas controladas; não são uma garantia universal de RAM nem uma certificação de “padrão ouro”.

## Checks locais

Apple Swift 6.1.2, Cargo 1.99.1, macOS arm64:

- `swift build --jobs 2` e build release do harness: passaram.
- `TRAMA_TEST_ENGINE_PATH="$PWD/Engine/target/debug/trama-engine" swift test --jobs 2 --no-parallel`: 161 testes passaram, incluindo a liberação das prévias removidas e integração com o motor real.
- Build Rust debug/release e `cargo test --locked --offline --manifest-path Engine/Cargo.toml -- --test-threads=1`, via `scripts/cargo-local.sh`: 38 testes passaram.
- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v`: 24 testes passaram.
- `scripts/render-workspace-preview.sh`: passou, incluindo a asserção de seis snapshots no modo completo. Inspecionadas as capturas da grade econômica em 820×560 e 1440×900: seletor e paginação cabem. Como no renderer anterior, a área SwiftTerm fica vazia na captura offscreen; isso não valida seus pixels.
- `CARGO_BUILD_JOBS=2 scripts/package-app.sh --release`: bundle local atualizado em `.build/Trama.app`, com assinatura ad hoc e verificação `codesign --verify --deep --strict` concluídas. O aplicativo em execução não foi reiniciado; é necessário reabri-lo para carregar a interface nova.
- Revisão independente do motor, interface, scripts, testes e evidências: sem bloqueadores restantes. `git diff --check` passou.

A tentativa inicial de testar cliques encontrou uma árvore de acessibilidade vazia no fixture; a cobertura foi delimitada ao comportamento que o harness consegue observar. A regressão de retenção falhou antes da correção de identidade do contêiner e passou depois. Uma execução concorrente das suítes excedeu o prazo de três segundos de um fixture de entrada preexistente; não foram alterados prazos de produto ou desse teste. A execução final explícita sem paralelismo passou integralmente.

Logs e executáveis locais ficam em `.build/memory-study/`; os JSONs sanitizados em `scripts/evidence/` permitem conferir amostras, hashes e confirmação de cleanup. As alterações de interface e desempenho já presentes no checkout foram preservadas.
