# Octo como referência nativa — 2026-11-14

Objetivo: aproximar a composição e o uso do Trama do Octo, preservando Swift 6, SwiftUI e AppKit no macOS 14+. Não há WebView nem execução do frontend HTML/JavaScript no aplicativo.

## Origem e escopo

A referência visual foi inspecionada no commit [`1dc08a44bc7698dbabfca37730de7df572d6091f`](https://github.com/lucasmarujo/octo/tree/1dc08a44bc7698dbabfca37730de7df572d6091f), incluindo `desktop/ui/index.html`, `styles.css`, `js/board.js`, `sidebar.js`, `grid.js` e as capturas `site/assets/octo-board-2x.webp` e `octo-agent.webp`. A licença MIT, copyright 2026 Lucas Marujo, foi lida antes da adaptação; seu texto está preservado em `ThirdPartyNotices/Octo-MIT.txt`.

Tokens de cor e composição foram traduzidos para SwiftUI. Imagens, fontes, ícones, marca e JavaScript do Octo não foram incorporados. O Trama mantém nome e símbolo próprios, tipografia do sistema e controles Apple. A referência de interface é distinta da dependência executável: o motor continua fixado em `f66aa854313026870aaf57f65d26d9cbfbf32269`; nenhum pin foi atualizado.

## Correspondência

| Octo | Trama nativo nesta entrega |
| --- | --- |
| Sessões na lateral, expansíveis, com agentes e contagem | Sessões reais do motor, expansão inicial da seleção, agentes clicáveis e nova sessão |
| Abas no alto, sem encerrar agentes ao fechá-las | Abas globais por identidade `id + createdAtMs`, acima do conteúdo |
| Cabeçalho da sessão e filtro de projeto | Nome da sessão, contagem de agentes/projetos e filtro separado da pasta da próxima tarefa |
| Quatro colunas e cartões densos | Atenção, execução, concluídos e espera, com rolagem independente; encerrados e estados desconhecidos continuam identificados |
| Cor por provedor, destaque de aprovação e worktree | Paleta traduzida, atenção amarela, interrupção vermelha, branch real e processo aninhado quando informado |
| Lista agrupada por projeto | Colunas de identidade, agente, tipo, estado e atividade |
| Grade de terminais | Snapshots reais, somente leitura, até seis por página, intervalo de três segundos entre respostas e cancelamento ao sair |
| Compositor fixo com provedor/pasta/opções | Chips nativos, pasta explícita, nome/sessão/worktree no popover e início em ⌘Return |
| Skills no compositor | Descoberta local ao digitar `/`; escolher insere a invocação, sem iniciar automaticamente |
| Terminal com painel de detalhes à direita | SwiftTerm/AppKit, painel de contexto em áreas largas e acesso a alterações, histórico, processos e PR/CI |
| Consumo na lateral | Apenas valores de consultas manuais confirmadas; cache em memória, com rolagem e sem números demonstrativos |

A seleção de sessão é persistida com as preferências de navegação. JSONs antigos sem esse campo continuam legíveis. Trocar sessão conserva abas e rascunhos; o modelo não usa uma lista ainda não carregada para apagar abas restauradas. O compositor e a lateral compartilham a mesma sessão. O modo Grade também é persistido.

## Diferenças e limites

Esta entrega não afirma paridade completa com o Octo atual. O motor fixado não expõe todos os recursos de seu frontend mais novo. Anexos, escolha de modelos, orquestrador/races, árvore lógica completa de subagentes e métricas completas de commits/testes/alterações não foram acrescentados. Tempo nos cartões é idade do registro, identificado na dica; não é tempo no estado atual.

Consumo automático, bypass de aprovação, exposição remota e atualizações automáticas não foram habilitados. Aprovações continuam no CLI; integração de worktree continua exigindo encerramento e confirmação. O shell não ganha autorização a partir da saída dos agentes. Atalhos principais são nativos: ⌘O, ⌘F, ⌘N e ⌘Return.

As prévias da grade não enviam input nem resize ao holder. O RPC de snapshot existente recebe somente o ID e não retorna timestamp: cancelar tarefas por identidade elimina respostas após substituição observada na lista, mas não comprova proteção contra uma substituição ocorrida entre list e snapshot. Esse limite de leitura já existia no detalhe; mutações mantêm a guarda de identidade.

## Responsabilidade e validação

O integrador cuidou de contratos, navegação persistida, shell, tema, quadro/lista e detalhe. Um agente implementou compositor e demonstração; outro implementou a grade. Um terceiro agente, sem autoria, revisou os diffs. Foram corrigidos e reverificados os achados de perda de abas antes do primeiro poll, sessão de destino divergente e painel de consumo sem rolagem.

As evidências e limitações desta entrega estão em [OCTO_NATIVE_VALIDATION.md](OCTO_NATIVE_VALIDATION.md). O histórico visual anterior continua em [UI_REFRESH_VALIDATION.md](UI_REFRESH_VALIDATION.md).
