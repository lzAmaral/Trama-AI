# Validação para apresentação do Trama

Validação local de 2026-11-15 para apresentar o aplicativo como **prévia funcional de um projeto pessoal**. Esta evidência não conclui os critérios de distribuição pública de [RELEASE_VALIDATION.md](RELEASE_VALIDATION.md).

## Ambiente e artefato

- Código do aplicativo: `9a239ad01142493802e2c729fec01b9f57fd0971`; alterações de apresentação em documentação não mudam o binário validado.
- Trama `0.1.0` (build `1`), macOS `26.6.2` (`25G83`), arm64.
- Swift `6.1.2`, Cargo `1.99.1`; motor Octo fixado em `f66aa854313026870aaf57f65d26d9cbfbf32269`.
- Bundle local separado: `.build/portfolio/Trama.app`, configuração release, arquitetura arm64.
- SHA-256 do executável Trama: `f8db1d22008580b8d1a489aca72223b46909309a8d5d7c754293c1b8ee813222`.
- SHA-256 do sidecar empacotado: `dfa9154ea1bb6b118ae9533436ccebe464123bff5930b11a4a20c0c227446c77`.

## Checks executados

| Verificação | Resultado |
| --- | --- |
| `swift build --jobs 2` | Passou |
| Swift com motor real e `--no-parallel` | 161 testes passaram; 29,459 s |
| Ferramentas Python (`unittest discover -s scripts/tests -v`) | 24 testes passaram; 10,142 s |
| Bundle release em diretório separado | Passou; recursos e motor incluídos |
| `codesign --verify --deep --strict` | Passou, com assinatura **ad hoc**; sem Team ID |
| Inspeção do sidecar empacotado | Provedor `terminal` detectado; armazenamento temporário vazio |
| Shell controlado pelo sidecar empacotado | Start, resize, input, snapshot, replay de logs e stop passaram |
| Saída do shell | 2.000 linhas, 182.000 bytes gerados, marcador de conclusão observado |
| Limpeza do teste de transporte | Todos os holders criados pelo teste confirmados como encerrados antes de remover o diretório temporário |

O smoke de transporte reutilizou `scripts/benchmark-engine.py`, com dois lotes. Ele usa uma cópia privada do binário, ambiente permitido explicitamente e pasta temporária; não inicia provedores de IA, não consulta consumo e não usa credenciais. Esse resultado comprova o sidecar empacotado, sem substituir a verificação da interface.

## Abertura e isolamento

O bundle foi aberto pelo LaunchServices, usando `NSWorkspace.openApplication` com uma nova instância e ambiente de validação. O callback retornou sucesso e o processo executou o binário do bundle separado. Não foi um duplo clique manual no Finder, nem uma validação da descoberta dos CLIs no PATH natural do Finder.

Foram definidos `HOME` e `CFFIXED_USER_HOME` para `.build/portfolio-validation/isolated-home`, `SHELL=/bin/sh` e `PATH=/usr/bin:/bin`. Antes de abrir o aplicativo, uma consulta Foundation confirmou que `URL.applicationSupportDirectory` e `FileManager.default.homeDirectoryForCurrentUser` respeitam esse isolamento. Depois da abertura, os arquivos de lock do Trama foram observados dentro desse diretório privado. Nenhuma configuração global foi alterada.

A inspeção por controle da interface confirmou a janela vazia, com zero projetos, zero agentes e Shell como única opção disponível. O diálogo **Adicionar projeto** abriu e permitiu navegação até uma pasta temporária, mas o controle automatizado não conseguiu concluir a seleção: o botão ficou desabilitado, a captura retornou uma imagem branca e ações subsequentes atingiram timeout. Isso não comprova um defeito do aplicativo e não conta como cadastro validado.

A primeira instância foi encerrada depois de conferir PID e caminho exato do executável. Para separar esse bloqueio do restante do fluxo, um projeto fictício `Demo local` foi cadastrado diretamente no arquivo de projetos do home isolado, antes inexistente, e o bundle foi aberto novamente. Essa preparação não equivale a cadastrar pela interface.

## Fluxo observado na interface

Na segunda instância, o controle da interface conseguiu selecionar **Pasta de destino**, escrever `printf 'TRAMA_%s\n' UI_OK` no compositor e acionar **Iniciar agente**. A árvore de acessibilidade confirmou a abertura automática da aba, o agente terminal `#1`, o estado **Disponível** e o projeto correto. Uma consulta posterior de snapshot pelo sidecar empacotado encontrou `TRAMA_UI_OK`, comprovando a execução do comando enviado pelo compositor. O marcador completo não estava presente na entrada, apenas na saída gerada pelo `printf`.

A captura do terminal retornou pequena e deformada, inadequada para revisão visual. Fechar a aba pela automação retornou `AXError.failure`; reabertura, entrada diretamente no terminal, resize e encerramento pela interface não foram comprovados nesta sessão. A inspeção da árvore de acessibilidade não equivale a um teste com VoiceOver.

Ao terminar, o agente criado pela UI foi encerrado pelo RPC `stop` no mesmo home isolado. Uma nova listagem confirmou todos os registros privados em estado `exited`. A segunda instância do aplicativo foi encerrada após conferir PID e caminho exato do executável, com término confirmado. Os demais aplicativos e agentes do usuário não foram encerrados. Portanto, há evidência de **criação pela UI e execução confirmada no motor**, com cleanup pelo sidecar; não de um ciclo completo operado pela UI.

## Reprodução e evidências locais

```sh
swift build --jobs 2
TRAMA_TEST_ENGINE_PATH="$PWD/Engine/target/debug/trama-engine" \
  swift test --jobs 2 --no-parallel
CARGO_BUILD_JOBS=2 ./scripts/package-app.sh --release \
  --output .build/portfolio/Trama.app
codesign --verify --deep --strict .build/portfolio/Trama.app
PYTHONDONTWRITEBYTECODE=1 python3 scripts/benchmark-engine.py \
  --engine .build/portfolio/Trama.app/Contents/MacOS/trama-engine \
  --batches 2 --output .build/portfolio-validation/bundled-engine-smoke.json
```

Logs e relatórios brutos locais, ignorados pelo Git: `.build/portfolio-validation/swift-build.log`, `swift-test.log`, `package.log`, `launch.log`, `launch-seeded.log`, `inspect.json`, `bundled-engine-smoke.json` e `ui-smoke.json`. O helper temporário `launch.swift` registra a configuração usada no LaunchServices. A reprodução dos testes Swift pressupõe o motor debug compilado, conforme o README.

## Limites para divulgação

Pode-se apresentar a implementação nativa, o terminal e os fluxos controlados com os resultados efetivamente observados. Execução autenticada e consulta de consumo de cada provedor continuam sem validação nesta entrega. VoiceOver, todos os estados de erro, interação prolongada e outra máquina também permanecem fora desta evidência.

O bundle tem assinatura local ad hoc. Developer ID, notarização real, compatibilidade com hardened runtime e Gatekeeper em outra máquina ainda precisam ser verificados antes de anunciar um download público pronto para instalação. Os avisos de dependências acompanham o bundle; a revisão final de distribuição continua conforme o roadmap.
