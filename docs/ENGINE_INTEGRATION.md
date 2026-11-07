# Integração do motor

## Arquitetura

A interface SwiftUI usa `OctoEngineClient` para executar `trama-engine` com argumentos separados e JSON via stdin/stdout. O executável depende da biblioteca `orkai` do Octo, revisão `f66aa854313026870aaf57f65d26d9cbfbf32269` (0.2.19). Os holders duráveis são lançados pelo motor; fechar uma janela ou cancelar uma consulta não os encerra.

Optamos por RPC de uma operação por processo, com polling do quadro a cada dois segundos e snapshot do terminal aberto a cada 800 ms. Isso permite reaproveitar Launcher/Store/client sem inicializar Hub/Peer, cujo watcher upstream consultaria consumo automaticamente. Não é um stream contínuo de terminal; alta frequência de digitação e saída merece medição antes da distribuição.

As [medições reproduzíveis](../scripts/VALIDATION.md) exercitam 3,64 MB de saída de shell controlado, com binário privado fixado por SHA-256 e cleanup confirmado. Elas medem transporte, JSON/base64 e probes, sem desenho do terminal ou digitação na UI. A avaliação desta entrega mantém RPC por operação: ainda é necessário medir latência de interação, renderização, CPU e memória do aplicativo antes de justificar a complexidade de conexão persistente, backpressure e reconexão de um stream. A pausa de polling se soma à duração de cada consulta; a medição do transporte não fecha o critério manual de desempenho da interface.

O binário também despacha `__holder`, `__agents` e `__hook`, necessários porque o launcher copia seu próprio executável. `__pwa-bridge` é recusado. Dados ficam exclusivamente no diretório do Trama; não há migração automática de instalações Octo.

## Contratos

`--inspect --home CAMINHO_ABSOLUTO` retorna versão de protocolo 1, origem/revisão fixada, provedores instalados, quantidade de registros e operações suportadas. Inspeção pode criar diretórios; não inicia holders, lê credenciais nem consulta rede. `agentCount` conta registros, não processos ativos.

`--request --home CAMINHO_ABSOLUTO` recebe um objeto JSON com `operation` e campos específicos. Resposta: `{"protocol":1,"ok":true,"result":...}` ou `{"protocol":1,"ok":false,"error":"..."}`. Input e snapshot transportam bytes em base64. Não há interpolação de tarefas em comandos de shell pelo cliente Swift.

| Operação | Comportamento |
| --- | --- |
| list | Registros, sessões e status consultado dos holders |
| start | Provedor, pasta, nome, tarefa, sessão e worktree opcional |
| send_prompt | Texto confirmado para IA já aberta; identidade, runtime autenticado e estados observados são conferidos; envio único sem retry |
| create_session | Cria agrupamento persistente |
| rename_session / move_agent | Renomeia agrupamento ou move registro; exige agentes afetados encerrados e destino sem colisão |
| input / resize / snapshot | Entrada PTY, dimensões e viewport ANSI |
| remove | Exclui registro/histórico de agente encerrado sem worktree, mediante confirmação |
| stop / resume | Encerra ou recupera somente sessão interrompida |
| skills | Descoberta upstream por provedor e projeto |
| logs | Replay do histórico persistido, limitado |
| export_logs | Prepara texto limitado com ocultações literais opcionais e aviso de revisão; não grava arquivos |
| log_retention / apply_log_retention | Prévia manual e exclusão confirmada dos arquivos revisados; token obsoleto é recusado |
| details | Registro e status, incluindo processo CLI aninhado quando detectado |
| process_tree | Snapshot limitado de descendentes locais por PID/nome, sem argumentos ou ambiente; não é árvore lógica completa |
| diff / merge | Alterações locais ou worktree; merge exige confirmação e holder encerrado |
| diff_snapshot | Diff sem ANSI com versão SHA-256, HEAD e identidade de criação; recusa captura excessiva ou UTF-8 inválido |
| review_preview / send_review | Prévia canônica e envio único de notas da mesma versão; identidade, token, confirmação e estado do provedor são revalidados |
| github_pr | Consulta manual de PR/checks pelo GitHub CLI; origem e branch validadas, identidade e versão local registradas |
| archive_worktree | Marca worktree encerrado como arquivado, preservando pasta, branch e alterações no lugar; não libera disco |
| usage | Consulta manual do provedor escolhido; exige `confirmed: true` |

Mutações persistentes usam lock de arquivo. Leituras de metadados e histórico também coordenam com esse lock para não observar renomeações parciais. Renomear sessão usa journal recuperável: a próxima operação coordenada conclui a gravação; journal inválido bloqueia a operação e permanece preservado. Renomear e mover exigem estado encerrado, pois o ambiente de um CLI já iniciado conserva o agrupamento anterior. `lost` não prova encerramento.

A UI serializa entrada e redimensionamento por terminal; outras consultas podem ocorrer em paralelo. Ao fechar detalhes ou observar encerramento, descarta a entrada ainda pendente. Uma entrada com resultado incerto não é reenviada automaticamente. O terminal não aceita comandos produzidos pela saída como autorizações. Aprovações permanecem sob controle do CLI.

As ações dos detalhes carregam o timestamp da identidade originalmente aberta. O motor recusa uma identidade substituída antes da mutação. Entrada e resize conectam uma vez ao holder autenticado, conferem a identidade novamente e usam essa mesma conexão, sem redirecioná-la a um ID reutilizado; não disputam o lock global com uma consulta lenta de GitHub. Chamadores legados que omitem o timestamp não têm a guarda inicial contra identidade obsoleta.

Inbox e revisão usam `id` + `createdAtMs`, no namespace do diretório do motor. O núcleo persiste observações, comentários, vínculos e métricas em arquivo próprio, sem modificar o armazenamento upstream. Observação ausente, desconhecida ou consulta falha não conclui intervenções. Abrir um item, entregar entrada ao PTY e concluir revisão são eventos distintos. O polling pode perder transições entre consultas; não é histórico completo do provedor.

Comentários ancoram linhas de conteúdo do snapshot exato, sem migração automática para outro diff. A prévia retorna o texto exato e um token ligado à versão e às notas. Envio exige confirmação explícita e uma IA viva do mesmo tipo, disponível ou concluída; shell, sessão interrompida, aprovação pendente e IA trabalhando são recusados. O reconhecimento confirma entrega ao PTY, sem comprovar execução ou sucesso do provedor. O fluxo detalhado e as medições locais ficam em [DELIVERY_WORKFLOW.md](DELIVERY_WORKFLOW.md) e [PILOT.md](PILOT.md).

PR/CI não é consultado pelo polling. Cada consulta autorizada usa `gh pr view` com argumentos separados e `github.com` explícito, sem criar, enviar ou integrar código. O snapshot vinculado guarda HEAD remoto/local, estado limpo do Git e versão do diff; checks não validam edições que não pertencem ao HEAD remoto. Forks e origens fora de `github.com` são recusados nesta entrega.

Arquivamento é um marcador próprio do Trama, sem `git add`, commit, remoção ou movimento da pasta. Inclui alterações staged, unstaged, untracked e ignored preservadas no lugar. O quadro permite mostrar os arquivados, e o sidecar bloqueia entrada, retomada e merge desses registros. Isso não torna o diretório imutável para ferramentas externas.

A exportação prepara uma prévia em memória. O usuário pode ocultar textos literais, revisar a prévia e salvar exatamente esse snapshot; a gravação não faz uma segunda consulta de logs. Retenção é manual: idade e tamanho por arquivo selecionam candidatos de agentes encerrados, e uma confirmação aplica o token da prévia. Não há limpeza automática nem quota global. Mudança nos candidatos invalida o token antes da primeira remoção. Falha de filesystem durante a exclusão pode deixar uma aplicação parcial; é necessário revisar outra prévia antes de tentar de novo.

## Limites

- Até 64 registros de agentes; probes paralelos limitados por essa quantidade.
- Solicitação até 64 KiB; entrada PTY até 32 KiB; UI agrupa até 24.000 bytes.
- Snapshot e diff até 512.000 bytes; envelope Rust até 900.000 bytes.
- Terminal entre 2–100 linhas e 10–240 colunas. A UI ajusta os pedidos a esses limites.
- Replay recusa arquivos de log acima de 16 MiB por arquivo e retorna os últimos 64 KiB de texto. Isso limita leitura/exibição, não constitui política de retenção de todo o armazenamento upstream.
- Ocultação literal na exportação aceita até 32 textos, 1024 bytes cada e 8192 bytes no total. Não identifica nem remove todos os segredos automaticamente.
- A árvore de processos contém no máximo 256 nós e sempre declara visibilidade incompleta. Relações `parentId` vêm de registros upstream; nome de executável não comprova relação lógica de subagentes. Não há controle por PID.
- Cliente Swift limita saída/tempo e descarta stderr. Nas novas operações de snapshot/revisão/PR, o processo estabelece um grupo privado para seus filhos transitórios; o cliente só cancela o grupo após conferir sua identidade. As operações anteriores continuam cancelando apenas o processo da solicitação. Após timeout de uma mutação, atualize o quadro antes de tentar novamente: a ação pode ter ocorrido. Não há retry automático.
- `nested` indica um processo CLI aninhado detectado no terminal, não uma árvore completa de subagentes.

## Reaproveitamento e validação

Registro/detecção, launch, hooks, holders, PTY, skills, logs, worktrees e adaptadores de consumo vêm do motor fixado. Os dez provedores aparecem no diagnóstico; somente os instalados ficam disponíveis para novas tarefas. Instalação não garante autenticação. As integrações autenticadas não foram exercitadas nesta entrega.

Testes Rust usam shell real e repositórios Git temporários para lifecycle, recuperação, resize, logs, diff e merge. Testes Swift verificam transporte, limites, cancelamento e o binário compilado. Testes não iniciam IA paga nem consultam consumo real.

O Trama não oferece paridade completa com a aplicação Octo: acesso remoto/PWA, árvores lógicas completas de subagentes e atualizador não estão conectados. Os controles de sessão cobrem agrupamento, renomeação e movimentação de registros encerrados. Assinatura Developer ID e notarização dependem da configuração de distribuição. Atualizar o motor exige revisar contratos, flags, persistência e regressões. O sidecar não isola o CLI em sandbox. A avaliação remota fica em [REMOTE_ACCESS.md](REMOTE_ACCESS.md), e os critérios externos em [RELEASE_VALIDATION.md](RELEASE_VALIDATION.md).
