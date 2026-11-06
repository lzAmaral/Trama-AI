# Integração do motor

## Arquitetura

A interface SwiftUI usa `OctoEngineClient` para executar `trama-engine` com argumentos separados e JSON via stdin/stdout. O executável depende da biblioteca `orkai` do Octo, revisão `f66aa854313026870aaf57f65d26d9cbfbf32269` (0.2.19). Os holders duráveis são lançados pelo motor; fechar uma janela ou cancelar uma consulta não os encerra.

Optamos por RPC de uma operação por processo, com polling do quadro a cada dois segundos e snapshot do terminal aberto a cada 800 ms. Isso permite reaproveitar Launcher/Store/client sem inicializar Hub/Peer, cujo watcher upstream consultaria consumo automaticamente. Não é um stream contínuo de terminal; alta frequência de digitação e saída merece medição antes da distribuição.

O binário também despacha `__holder`, `__agents` e `__hook`, necessários porque o launcher copia seu próprio executável. `__pwa-bridge` é recusado. Dados ficam exclusivamente no diretório do Trama; não há migração automática de instalações Octo.

## Contratos

`--inspect --home CAMINHO_ABSOLUTO` retorna versão de protocolo 1, origem/revisão fixada, provedores instalados, quantidade de registros e operações suportadas. Inspeção pode criar diretórios; não inicia holders, lê credenciais nem consulta rede. `agentCount` conta registros, não processos ativos.

`--request --home CAMINHO_ABSOLUTO` recebe um objeto JSON com `operation` e campos específicos. Resposta: `{"protocol":1,"ok":true,"result":...}` ou `{"protocol":1,"ok":false,"error":"..."}`. Input e snapshot transportam bytes em base64. Não há interpolação de tarefas em comandos de shell pelo cliente Swift.

| Operação | Comportamento |
| --- | --- |
| list | Registros, sessões e status consultado dos holders |
| start | Provedor, pasta, nome, tarefa, sessão e worktree opcional |
| create_session | Cria agrupamento persistente |
| input / resize / snapshot | Entrada PTY, dimensões e viewport ANSI |
| remove | Exclui registro/histórico de agente encerrado sem worktree, mediante confirmação |
| stop / resume | Encerra ou recupera somente sessão interrompida |
| skills | Descoberta upstream por provedor e projeto |
| logs | Replay do histórico persistido, limitado |
| details | Registro e status, incluindo processo CLI aninhado quando detectado |
| diff / merge | Alterações locais ou worktree; merge exige confirmação e holder encerrado |
| usage | Consulta manual do provedor escolhido; exige `confirmed: true` |

Mutações persistentes usam lock de arquivo. A UI serializa entrada e redimensionamento por terminal; outras consultas podem ocorrer em paralelo. O terminal não aceita comandos produzidos pela saída como autorizações. Aprovações permanecem sob controle do CLI.

## Limites

- Até 64 registros de agentes; probes paralelos limitados por essa quantidade.
- Solicitação até 64 KiB; entrada PTY até 32 KiB; UI agrupa até 24.000 bytes.
- Snapshot e diff até 512.000 bytes; envelope Rust até 900.000 bytes.
- Terminal entre 2–100 linhas e 10–240 colunas. A UI ajusta os pedidos a esses limites.
- Replay recusa arquivos de log acima de 16 MiB por arquivo e retorna os últimos 64 KiB de texto. Isso limita leitura/exibição, não constitui política de retenção de todo o armazenamento upstream.
- Cliente Swift limita saída/tempo, descarta stderr e cancela apenas o processo da solicitação. Após timeout de uma mutação, atualize o quadro antes de tentar novamente: a ação pode ter ocorrido. Não há retry automático.
- `nested` indica um processo CLI aninhado detectado no terminal, não uma árvore completa de subagentes.

## Reaproveitamento e validação

Registro/detecção, launch, hooks, holders, PTY, skills, logs, worktrees e adaptadores de consumo vêm do motor fixado. Os dez provedores aparecem no diagnóstico; somente os instalados ficam disponíveis para novas tarefas. Instalação não garante autenticação. As integrações autenticadas não foram exercitadas nesta entrega.

Testes Rust usam shell real e repositórios Git temporários para lifecycle, recuperação, resize, logs, diff e merge. Testes Swift verificam transporte, limites, cancelamento e o binário compilado. Testes não iniciam IA paga nem consultam consumo real.

O Trama não oferece paridade completa com a aplicação Octo: acesso remoto/PWA, árvores completas de subagentes, edição avançada de sessões e atualizador não estão conectados. Assinatura Developer ID e notarização dependem da configuração de distribuição. Atualizar o motor exige revisar contratos, flags, persistência e regressões. O sidecar não isola o CLI em sandbox.
