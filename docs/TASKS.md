# Tarefas da integração

O integrador define contratos, delega arquivos exclusivos e integra após revisão cruzada. Testes de CLI autenticado e verificação visual são critérios separados da compilação.

## Área de projeto e envio de tarefas — 2026-11-07

Escopo solicitado pelo usuário após testar a interface: reproduzir o fluxo útil do Octo para saber projeto ativo, agentes abertos e destino do prompt. Branch `feat/project-agent-workspace`, sobre a PR #4; Run Orca `run_6ee538fc19aa`. Contratos, referência MIT e limites em [WORKSPACE_FLOW.md](WORKSPACE_FLOW.md).

| Responsável / tarefa | Ownership e resultado |
| --- | --- |
| Núcleo — `task_b11e55f8d807` | Novos WorkspaceNavigationState/Repository e 17 testes: projeto, abas por identidade, restauração, erro/corrupção, lock e reset com backup |
| Motor — `task_cede420e0137` | RPC send_prompt e startIdentified, modelos/cliente e testes Swift/Rust; sem iniciar IA paga em testes |
| Interface — `task_2556370a5cd7`, correções `task_edf9dfa69067` | Detalhe embutido, compositores, nomes automáticos, foco, painel solicitado e dimensões; sem edição da raiz |
| Integrador | TramaApp, LiveWorkspaceModel/View, target TramaAppTests e 8 testes de apresentação, docs, integração, bundle e Git |
| Revisão — `task_ca1bfe6eae1a`, revalidação final | Autor do motor revisa navegação/App de outros autores por leitura; achados de seleção inicial, nomes, foco, altura, pending e roteamento atribuídos e corrigidos |
| Revisão — `task_4e5ae342c057`, correções `task_ea9875977bd0` | Outro autor reproduziu status paused já enfileirado e divergência Unicode; correção com parser limitado/último status e Cc alinhado foi revalidada independentemente com TCP controlado, 7 testes Rust e 5 Swift |

Os rascunhos são somente memória. Fechar aba não encerra processo. Nenhuma captura do Octo foi usada como dado de teste ou transformada em recurso do aplicativo. A ferramenta de controle do computador recusou novamente o Trama; inspeção visual e teclado real não foram executados nem substituídos pela compilação. Suítes paralelas de processos geraram timeouts locais; o fechamento executa Rust sem concorrência entre casos e registra essa limitação, sem alterar prazos de produto.

Fechamento local: `swift test` com `TRAMA_TEST_ENGINE_PATH` passou **132 testes**, incluindo **9 AppTests** de comportamento do modelo/compositor, sem pular as integrações opt-in. Cargo build locked e Cargo test locked/offline com `--test-threads=1` passaram **35 testes** (3 unitários, 12 delivery, 7 prompt e 13 lifecycle). As **16 verificações Python** passaram; avisos cobrem ambos os targets macOS, e `git diff --check` está limpo. O bundle isolado `.build/validation/Trama.app` foi regenerado após as correções e passou `codesign --verify --deep --strict` com assinatura ad hoc. A última revalidação de UI (`task_02a2ea12e2ac`) confirmou navegação/altura por leitura e apontou filtro Cf restante no compositor; integrador alinhou Cc e verificou o teste da própria política da view com ZWJ/ZWNJ e controles C0/C1.

## Supervisão e entrega — 2026-11-07

Escopo autorizado pelo usuário: inbox de intervenções, comentários no diff, vínculo de PR/CI e preparação de piloto com métricas locais. Run Orca `run_34152863a708`, branch `feat/review-delivery-workflow`, sobre a entrega da PR #3. Contratos de comportamento em [DELIVERY_WORKFLOW.md](DELIVERY_WORKFLOW.md) e roteiro em [PILOT.md](PILOT.md).

| Responsável / tarefa | Objetivo e ownership | Dependências / aceite |
| --- | --- | --- |
| Núcleo — `task_e3fe81f47c34` | Novos `DeliveryWorkflowModels.swift`, `DeliveryWorkflowRepository.swift` e testes correspondentes | Contratos aprovados antes de implementar; persistência atômica/lock, corrupção, transições, concorrência e métricas opt-in testadas |
| Motor — `task_7900557cf79a` | RPC de snapshot/preview/envio e PR/CI; `rpc.rs`, novo `rpc_delivery.rs`, testes novos, manifest/lock se necessário, modelos/cliente Engine Swift e testes novos | Pin preservado; Git/CLI falsos controlados; versões/identidade/âncoras, confirmação, destinos, timeout e cancelamento testados |
| Interface — `task_25419dc71e35` | `Sources/TramaApp/*.swift`, inbox, revisão, PR/CI, notificações opt-in e piloto | Consome contratos aprovados; visto/resposta distintos, prévia exata, ausência de requests automáticos, estados de erro/stale, teclado e build |
| Integrador | Contratos compartilhados, docs, avisos gerados se lock mudar, CI, checks finais, bundle isolado e Git | Revisão independente por outro autor, validação Swift/Rust/ferramentas e registro de limites reais |

Não há recrutamento ou pesquisa com participantes concluídos pela criação da instrumentação. Testes não chamam provedores pagos, contas reais de GitHub, consultas de consumo nem APIs de notificação do usuário. Abrir o quadro não consulta PR/CI automaticamente; envio de revisão depende de prévia, confirmação e estado adequado do provedor.

Revisões independentes: `task_eff0a976d762` (autor do núcleo revisou App/docs, sem editar) e `task_37ad28541a8e` (autor da interface revisou núcleo/motor, sem editar). Achados reproduzidos levaram à correção de filtros Git clean/process durante leitura, troca de branch/origin durante consulta de PR, ACK posterior à resolução observada, confirmação aberta sobre ID reutilizado, opt-out de notificações entre janelas e inserção de nota seguida de falha no refresh. O integrador também corrigiu a primeira leitura de arquivo ausente (Cocoa 4/260), reduziu lotes pela UI e removeu a âncora de rascunho ao atualizar a versão. A contenção entre consulta PR e terminal foi corrigida usando a mesma conexão autenticada após revalidar a identidade; o revisor confirmou o teste com barreira e os dois revisores encerraram sem bloqueadores remanescentes.

Validação final local: `./scripts/build-engine.sh` (Cargo build locked + Swift build), `TRAMA_TEST_ENGINE_PATH="$PWD/Engine/target/debug/trama-engine" swift test` com **101 testes passando**, Cargo test locked/offline com **28 testes passando** (3 unitários, 12 de entrega e 13 de lifecycle), ferramentas Python **16 testes passando**, avisos completos nos dois grafos macOS e `git diff --check` limpo. O bundle isolado `.build/validation/Trama.app` foi gerado e sua assinatura ad hoc verificada com `codesign --verify --deep --strict`. Sem provedores pagos, autenticação/rede de produto ou chamadas de notificação reais. A suíte do núcleo tem 26 testes; o número 25 citado durante implementação era uma estimativa, não resultado de execução.

O usuário escolheu começar o piloto consigo mesmo. O roteiro e a instrumentação estão prontos; a sessão de uso e seus resultados ainda não foram realizados. Revisão visual/VoiceOver e notificações reais continuam pendentes, sem contornar a recusa anterior de acesso ao aplicativo pela ferramenta de controle do computador.

## Fechamento local — 2026-11-07

Execução supervisionada pela skill Orca `orchestration`, Run `run_5a079d025dc2`, na branch `feat/remaining-local-capabilities`. A autorização abrange as capacidades planejadas; testes continuam restritos a processos controlados, sem tarefas pagas, leitura de credenciais ou publicação automática.

| Responsável / tarefa Orca | Objetivo e arquivos exclusivos | Dependências / aceite |
| --- | --- | --- |
| Motor — `task_595f34f7317f` | Sessões, worktrees, histórico e avaliação de árvore observável; `Engine/src/rpc.rs`, módulos novos, testes Rust, `EngineSessionModels.swift`, `OctoEngineClient.swift` e testes de contrato/integração correspondentes | Contratos aprovados pelo integrador antes da implementação; upstream fixado; shell/Git temporários e erros testados |
| Interface — `task_74fad74e1a15` | Teclado, acessibilidade, estados de apresentação e conexão das capacidades aprovadas; `Sources/TramaApp/*.swift`, mais a fila `TerminalActionQueue.swift` e seus testes por alinhamento do integrador | Melhorias iniciais independentes; novos controles usam contrato aprovado do motor; build e testes comportamentais da fila |
| Distribuição — `task_42593c81204f` | Avisos transitivos reproduzíveis, medição de transporte com saída intensa e preparação opt-in da distribuição; `scripts/*` e `ThirdPartyNotices/*` | Sem identidade/certificado, envio à Apple ou publicação; validar scripts, preservar bundle anterior em falha e registrar números reais |
| Integrador | Contratos, documentação, CI, validação integrada, revisão visual quando disponível e coordenação da revisão independente | `swift build`, `swift test` com motor real, build/test Rust locked, diff completo e `git diff --check` |

Antes da integração, outro worker revisa o código de cada autor. Validações autenticadas, Developer ID/notarização e revisão de um atualizador com canal autenticado exigem evidências próprias; não se tornam concluídas pela criação de scripts. A árvore de processos observável não comprova a árvore lógica de subagentes dos provedores. Acesso remoto permanece objeto de avaliação separada, sem listener, túnel ou bridge habilitado.

| ID | Entrega | Dependências | Estado e evidência |
| --- | --- | --- | --- |
| E01 | Biblioteca Rust fixada + inspeção | — | Implementado; contrato real testado |
| E02 | Cliente Swift do motor | E01 | Implementado; JSON, prazos, cancelamento e limites testados |
| E03 | Diagnóstico nativo | E02 | Implementado; revisão visual manual pendente |
| E04 | RPC e lifecycle de holders | E01 | Implementado via requisições pontuais/polling; shell real testado sem Hub/Peer |
| E05 | Quadro real | E04 | Implementado; filtros, busca, estados lost/exited; revisão visual pendente |
| E06 | Terminal nativo | E04 | SwiftTerm, entrada, resize e snapshot; PTY testado; interação visual pendente |
| E07 | Execução de provedores | E05, E06 | Launcher conectado e aprovações preservadas; smoke autenticado de cada CLI pendente |
| E08 | Sessões, recuperação e skills | E04 | Implementado; recuperação, renomeação e movimento de registros encerrados testados; parentesco registrado/processos locais incompletos, sem árvore lógica universal |
| E09 | Worktrees, diff, merge e arquivo | E04 | Implementado; shell + Git temporários, confirmação e bloqueio de agente vivo; arquivo no lugar preserva staged/unstaged/untracked/ignored e branch, sem liberar disco |
| E10 | Consumo opcional | E02 | Implementado manualmente; contrato e rejeição sem consentimento testados; endpoint/conta real por provedor pendentes |
| E11 | Empacotamento | E05, E06 | Bundle isolado ad hoc verificado; ferramenta de distribuição opt-in testada com fixtures; Developer ID/notarização reais pendentes; política de atualização documentada, sem atualizador |
| E12 | Logs revisáveis | E04, E06 | Exportação salva prévia exata após revisão; retenção manual exige candidatos/token e confirmação, com testes de estado, symlinks e plano obsoleto |
| E13 | Transporte sob carga | E04 | Duas medições de shell controlado com 3,64 MB; não mede desenho, digitação ou CPU/memória da UI |

## Responsabilidades da integração inicial

- Motor: RPC, lifecycle, validação e testes Rust.
- Transporte Swift: modelos, cliente e testes de contrato/integração.
- Terminal: SwiftTerm, revisão cruzada das views e bundle.
- Integrador: quadro/composer/detalhes/consumo, revisão do motor/cliente, documentação, checks e Git.

Arquivos compartilhados só mudam após alinhamento. Não há execução automática de tarefas pagas nos testes. Falhas de timeout não autorizam retry automático de mutações.

## Próximos critérios externos

1. Abrir o bundle e revisar teclado, acessibilidade, estados vazios/erro, seleção e redimensionamento com o usuário.
2. Validar tarefa curta em cada provedor instalado/autenticado, incluindo pedido de aprovação e interrupção.
3. Consultar consumo manualmente em cada conta que o usuário escolher e revisar o adaptador correspondente.
4. Configurar assinatura/notarização quando houver identidade de distribuição e revisar as obrigações de avisos/fontes correspondentes; textos do grafo macOS já foram reunidos.

Acesso remoto, árvores completas de subagentes e atualizações automáticas exigem entregas próprias; não são recursos habilitados nesta versão.

## Resultado do fechamento local

As oito tarefas Orca foram concluídas e seus workers liberados. As tarefas de revisão concluíram a análise; os achados não foram tratados como implementação pronta até que outro autor corrigisse e o revisor verificasse os cenários novamente.

| Tarefa | Resultado / evidência |
| --- | --- |
| `task_595f34f7317f` — motor/núcleo | Contratos locais implementados; shell/Git, persistência e falhas verificados |
| `task_74fad74e1a15` — interface/fila | Controles conectados, estados e teclado revisados em código; fila testável sem SwiftUI |
| `task_42593c81204f` — ferramentas | Avisos, benchmark, bundle isolado e preparação opt-in de distribuição; evidências em `scripts/VALIDATION.md` |
| `task_e5c66a189dee` — revisão motor/interface | Reproduziu journal inválido, seleção inexistente e resize A/B/A; correções de outros autores reverificadas, sem bloqueadores remanescentes |
| `task_92011c195290` — revisão ferramentas | Identificou gravação incompleta dos avisos e cleanup ausente em HUP; confirmou preservação de bytes CRLF após ajuste de atributos |
| `task_1f3dfedef3c7` — correções da interface | Seleção só usa sessões existentes; último resize prevalece sem perder reaplicação após retomada; 17 testes corretivos e harness independente aprovados |
| `task_aaeaf81aad92` — correções motor/ferramentas | Journal valida snapshots completos antes de gravar; avisos usam staging; cleanup adia sinais tardios até confirmar encerramento ou informar recuperação |
| `task_d1b0dfb0f9a9` — revisão final das ferramentas | Revalidou falhas de escrita/retry e sinais inclusive durante cleanup; conferiu JSONs/hash e avisos do bundle, sem bloqueadores remanescentes |

Validação final do integrador com Swift 6.1.2 e toolchain Rust 1.99.1:

- `swift build` e `TRAMA_TEST_ENGINE_PATH="$PWD/Engine/target/debug/trama-engine" swift test`: 66 testes aprovados, sem integrações ignoradas.
- Build/test Rust com `--locked --manifest-path Engine/Cargo.toml`: 15 testes aprovados (2 unitários e 13 de lifecycle).
- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v`: 16 testes aprovados, incluindo oito subcasos de sinais.
- Checks dos avisos de `aarch64-apple-darwin` e `x86_64-apple-darwin` aprovados: 184 pacotes inventariados, 150 textos distintos, zero faltantes nos dois grafos macOS. O check global retorna 1 para duas ausências Windows declaradas.
- Bundle `.build/validation/Trama.app` compilado e verificado com assinatura ad hoc estrita; o app em uso foi preservado. Avisos comparados byte a byte, com line endings originais preservados no Git.
- Diff de fonte revisado, arquivos gerados conferidos por hash e `git diff --check` aprovado. O CI ampliado executa testes das ferramentas, checks de avisos e bundle isolado; a evidência remota fica registrada na PR.

Limites: CUA recusou acesso ao Trama, portanto não houve revisão visual, VoiceOver ou gravação. Não foram executadas tarefas de IA pagas, consultas autenticadas de consumo, certificados, notarização ou publicação. A árvore lógica universal de subagentes continua aberta; o recurso implementado observa somente registros e processos locais. Arquivamento não libera disco nem permite desarquivar nesta entrega; retenção manual pode ter efeito parcial em erro de I/O, e ocultação literal não garante remoção de todos os dados sensíveis. SIGKILL/perda de energia podem impedir cleanup. Consulte [ROADMAP.md](ROADMAP.md) e [RELEASE_VALIDATION.md](RELEASE_VALIDATION.md).

## Cadastro entre instâncias — 2026-11-07

- Objetivo: impedir perda de projetos quando duas instâncias cadastram pastas a partir de listas desatualizadas.
- Responsável: integrador; revisão independente por agente sem autoria do código.
- Arquivos: `ProjectRepository.swift`, `TramaApp.swift`, `ProjectRepositoryTests.swift` e documentação desta entrega.
- Contrato: `register(_:)` relê, deduplica e grava sob lock exclusivo não bloqueante; retorna projeto selecionado e snapshot atualizado. `save(_:)` continua sendo substituição explícita do snapshot.
- Dependências: persistência atômica existente e validação canônica de pastas; sem mudanças no motor.
- Aceite verificado: duas instâncias com listas antigas preservam os dois cadastros; duplicata mantém identidade; lock ocupado rejeita a operação sem alterar os dados; arquivo corrompido permanece intacto e o lock é liberado após erro.
- Validação: `swift build`, `swift test` e `git diff --check` aprovados com Swift 6.1.2. Runner reportou 42 testes e dois testes de integração Rust ignorados por dependerem de configuração explícita. Revisão independente sem bloqueadores.
- Limitações: não houve revisão visual com dois aplicativos abertos; contenção foi testada com descritores independentes no mesmo processo. Não há atualização visual automática entre instâncias nem proteção contra versões antigas que não usam o lock.
