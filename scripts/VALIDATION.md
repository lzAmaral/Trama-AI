# Evidências locais das ferramentas

Execução em 2026-11-07, macOS arm64, Python 3.13.7. Estes resultados medem ferramentas locais; não comprovam UX visual, autenticação de provedores ou distribuição pública.

## Inventário

`./scripts/generate-notices.py` coletou 184 pacotes externos, 150 textos distintos e dois faltantes Windows declarados em `ThirdPartyNotices/generated/inventory.json`. `--check --target aarch64-apple-darwin` e `--check --target x86_64-apple-darwin` passaram; `--check` global retornou 1 como esperado para os dois faltantes. Os dois grafos macOS contêm 151 pacotes Cargo externos, mais dois pins Swift. O gerador usa `cargo metadata --locked --offline`; não baixa fontes, não muda os manifests e não inicia Hub/Peer.

A geração valida a propriedade da saída anterior antes de montar uma cópia completa em staging no mesmo filesystem. Somente após todas as escritas concluírem usa `publish-directory.py` para publicar, com rollback e backup recuperável em falha dupla. Uma escrita incompleta não troca o inventário nem mistura gerações; a segunda execução pode tentar novamente sem remover arquivos manualmente. A troca não garante atomicidade contra perda de energia entre renames.

## RPC e terminal sob saída intensa

Reprodução com motor previamente compilado:

```sh
./scripts/benchmark-engine.py --engine .build/validation/Trama.app/Contents/MacOS/trama-engine --output '.build/benchmark pressure.json'
./scripts/benchmark-engine.py --engine .build/validation/Trama.app/Contents/MacOS/trama-engine --poll-pause 0.8 --output '.build/benchmark cadence.json'
```

Cada execução fixa uma cópia privada do executável para que rebuilds concorrentes não alterem o motor medido, cria um home e projeto temporários com espaços no caminho, usa um ambiente permitido explicitamente (`HOME` temporário, `/bin/sh`, `PATH=/usr/bin:/bin`) e inicia somente um terminal. O gerador local escreve 40 lotes de 1.000 linhas de 91 bytes, total 3.640.000 bytes antes da expansão de CR pelo PTY, com pausa de 100 ms por lote. Snapshots usam 100×240 células. A conclusão é observada no snapshot; o próprio holder é encerrado antes de verificar replay para garantir flush do log. `finally` enumera apenas o home privado e confirma que todos seus registros estão encerrados; se não conseguir, preserva o home e falha. Evidência anterior só é substituída depois de sucesso e cleanup confirmado.

SIGINT, SIGTERM e SIGHUP passam pelo mesmo cleanup, inclusive quando o terminal é fechado. Durante o próprio cleanup, esses sinais ficam adiados até terminar o encerramento, a confirmação e o diagnóstico de recuperação. Fixtures em subprocessos enviam os sinais reais durante input e durante a listagem de cleanup após start incerto; verificam a chamada de `stop`, a remoção do home após confirmação e sua preservação com diagnóstico quando o encerramento falha. SIGKILL e perda de energia não permitem executar cleanup: podem deixar o holder durável e o home temporário para recuperação manual. Os tempos de `loadedList` usam as primeiras `count` amostras sob carga; `rpcMs.list` também inclui as duas consultas posteriores de cleanup, e `rpcEnvelopeBytes` conserva baseline e cleanup.

| Cenário | Tempo até conclusão observada | Amostras sob carga | Snapshot mediana / p95 | List mediana / p95 |
| --- | ---: | ---: | ---: | ---: |
| Pausa 50 ms entre ciclos | 5,273 s | 56 | 36,584 / 42,512 ms | 3,395 / 6,920 ms |
| Pausa 800 ms entre ciclos | 6,026 s | 8 | 47,276 / 66,218 ms | 4,406 / 6,908 ms |

Dados completos, baseline, tamanho de envelopes, tempos individuais, plataforma e SHA-256 do binário estão em [evidence/benchmark-pressure.json](evidence/benchmark-pressure.json) e [evidence/benchmark-ui-cadence.json](evidence/benchmark-ui-cadence.json). As duas medições usam o mesmo sidecar do bundle validado, SHA-256 `2a601d45f50355eb883cb11cfb8c764413e09bb9be1388fcce5ba4e5e02956c4`. São duas execuções, não uma distribuição estatística de máquinas/cargas. `p95` usa nearest rank; a mediana usa o elemento central superior quando a contagem é par, e a amostra de oito ciclos é pequena. A pausa se soma ao tempo das operações: não é amostragem de frequência fixa. O cenário de 800 ms aproxima a pausa do terminal documentada, mas adiciona listagem sequencial por ciclo e não replica o scheduler SwiftUI. O resultado inclui criação de processo por RPC, transporte JSON/base64 e consultas do holder; não inclui cliente Swift, desenho do terminal, digitação, consumo de CPU/memória da UI, providers ou rede. Snapshot de viewport e replay limitado não provam transporte integral sem perdas do histórico. Nenhuma tarefa paga foi iniciada.

## Publicação local e distribuição opt-in

`package-app.sh --output .build/validation/Trama.app` permite validar em destino separado sem substituir o app aberto. O destino deve ser um diretório `.app` real dentro de `.build`, fora de outro bundle. Sem esse argumento, `package-app.sh` mantém o destino padrão e o comportamento ad hoc e usa `publish-directory.py` para trocar o bundle concluído. A publicação salva o artefato anterior fora do staging, restaura-o se o segundo rename falhar e preserva um caminho recuperável se publicação e rollback falharem. Não fornece atomicidade contra perda de energia entre os dois renames.

`distribute-app.sh --help` documenta o opt-in. Exemplo para execução futura pelo responsável pelos certificados:

```sh
./scripts/distribute-app.sh --identity 'Developer ID Application: Nome (TEAM)'
# Upload à Apple ocorre SOMENTE com estes dois argumentos adicionais explícitos:
./scripts/distribute-app.sh --identity 'Developer ID Application: Nome (TEAM)' --notarize --keychain-profile 'perfil-existente'
```

O script copia o app já compilado, aplica hardened runtime e timestamp, verifica assinatura, e escreve `.build/distribution` separado do bundle de desenvolvimento. Com opt-in de notarização, exige status `Accepted`, staple e validação; recria o ZIP depois do staple. Falhas deixam o bundle fonte e distribuição anterior preservados. Não procura identidades, não cria perfis, não recebe senhas, não altera keychain/configuração global e não imprime identidade/perfil ou stderr dos serviços. O caminho real com Developer ID/notarização **não foi executado**; testes usam executáveis falsos. Entitlements, aprovação de notarização, abertura/Gatekeeper em outra máquina, política de atualização autenticada e distribuição permanecem validações externas.

## Testes

`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v` passou 16 testes: conteúdo/hash do inventário, publicação com espaços, preservação em falha de assinatura, falha de rename com rollback, falha dupla com backup fora do staging, rejeição de destino arquivo, recusa de output estranho/symlink, falha de escrita de avisos com geração anterior intacta e segunda execução bem-sucedida, parser e destino isolado do bundle, sinais HUP/TERM/INT em subprocesso, preservação de home quando stop falha, opt-in obrigatório, rejeição de notarização sem vazamento do perfil e ZIP contendo staple em fixtures controladas. Não usa certificados nem envia à Apple. `sh -n scripts/*.sh` e `git diff --check` passaram.

`./scripts/package-app.sh --output .build/validation/Trama.app` passou novamente após as correções, com Cargo build locked debug e Swift build debug; assinatura ad hoc e `codesign --verify --deep --strict` passaram. Os 155 arquivos de avisos no bundle (151 gerados) foram comparados byte a byte com a origem, e `SwiftTerm_SwiftTerm.bundle` foi encontrado em Resources. O destino padrão do app em uso não foi substituído.

`cargo build` e `cargo test` via `scripts/cargo-local.sh`, com `--locked --offline --manifest-path Engine/Cargo.toml`, passaram após a correção do journal: 2 testes unitários e 13 testes de lifecycle. As regressões verificam recusa de snapshots adulterados ou incompletos sem mudar registros, sessões ou journal, além de recuperação parcial válida. Revisores independentes aprovaram a correção do motor e os scripts com reproduções próprias. `swift test` e revisão integrada do conjunto final pertencem ao integrador; este worker não os declara executados.
