# Navegação por projeto

A lateral apresenta projeto → sessão → agentes. Cada projeto possui uma sessão inicial **Geral**, disponível mesmo vazio. Criar sessões e renomeá-las mantém o vínculo com o projeto, inclusive antes da primeira tarefa e depois de reabrir o aplicativo. Nomes como “Landing page” podem ser usados em projetos diferentes sem compartilhar o agrupamento de novas tarefas.

Selecionar outro projeto limpa o filtro da sessão anterior. A lateral não acrescenta uma sessão apenas porque ela estava selecionada; o compositor, o formulário de novo agente e o destino de movimentação oferecem somente as sessões daquele projeto. Selecionar a pasta de destino de outro projeto usa sua sessão inicial. Abas e rascunhos são preservados, sem iniciar, encerrar ou mover processos pela navegação.

O catálogo `trama-project-sessions.json`, dentro do diretório isolado do motor, guarda projeto, identidade do agrupamento, nome de exibição e indicação de gerenciamento pelo Trama. Usa versão, limite de 256 KiB, lock estável, releitura antes de modificar e gravação atômica. Corrupção ou versão desconhecida preservam os bytes e bloqueiam novas tarefas dependentes do catálogo; uma leitura malsucedida não apaga a seleção de uma sessão vazia. Redefinir preferências de navegação não apaga o catálogo.

Novas sessões usam identidades de 32 caracteres compatíveis com o Store upstream. O nome exibido fica no catálogo e pode mudar enquanto agentes trabalham. “Nova sessão” cria o vínculo local; o agrupamento correspondente no motor é materializado somente ao iniciar uma tarefa ou mover um registro por ação explícita. Essa preparação consulta o snapshot atual, revalida o projeto e aceita criação concorrente já confirmada pelo motor; não repete a operação de iniciar agente.

Sessões legadas continuam acessíveis nos projetos que contêm seus agentes; worktrees usam o projeto original. Um nome local também pode ser atribuído a uma sessão legada sem alterar sua identidade, tarefas ou processos. Renomear na interface afeta somente aquele projeto. Aliases legados ausentes do motor não são recriados automaticamente. Sessões legadas compartilhadas continuam compartilhadas internamente: os agentes não são migrados por esta entrega. O RPC `rename_session` mantém seu comportamento global para clientes que o chamem diretamente.

Sessões legadas vazias sem vínculo local ou com agentes fora dos projetos cadastrados permanecem em “Outras sessões”. Arquivados continuam disponíveis pela opção do quadro. O caminho da pasta de destino permanece explícito no compositor.

## Entrega de 2026-11-15 — Geral e vínculo persistente

Objetivo: substituir o destino global implícito por uma sessão inicial do projeto e preservar sessões vazias e nomes locais. O integrador ficou responsável pelos modelos/repositório de sessões, navegação, views, testes e roteiro de prévia. O contrato RPC e o pin do motor não mudaram. Um segundo agente revisou comportamento, falhas e testes sem editar os arquivos da implementação.

Validação com Swift 6.1.2:

- `swift build` passou.
- `TRAMA_TEST_ENGINE_PATH="$PWD/Engine/target/debug/trama-engine" swift test`: 172 testes passaram, incluindo motor compilado com armazenamento temporário. A nova integração verifica criação de agrupamentos próprios, repetição idempotente da preparação, recusa de destino de outro projeto e ausência de agentes iniciados.
- Regressões cobrem projeto vazio, seleção obsoleta, nomes iguais em projetos distintos, persistência entre instâncias, renomeação local de sessão ativa, corrupção, falha de gravação, catálogo indisponível e sessão legada removida.
- `scripts/render-workspace-preview.sh --project-sessions` gerou duas capturas offscreen com dados fictícios: projeto com agentes e sessão vazia nomeada (1024 × 640), e outro projeto vazio com seu próprio Geral (820 × 560). As capturas foram inspecionadas em `.build/octo-native-previews/sessions-populated.png` e `sessions-empty.png`.
- Revisão independente e `git diff --check` passaram.

Os testes não iniciam IA paga. As capturas não substituem a revisão interativa, VoiceOver nem desempenho prolongado. O catálogo é necessário para restaurar os nomes de novas sessões; backups devem incluir o diretório completo do motor. A versão anterior do aplicativo não interpreta esses nomes locais.
