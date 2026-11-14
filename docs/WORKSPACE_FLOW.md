# Área de trabalho por sessão e projeto

A interface segue agora a composição do Octo: sessões na lateral, abas no topo, quadro por estado e compositor fixo. A referência atual, o mapeamento e os limites estão em [OCTO_NATIVE_PARITY.md](OCTO_NATIVE_PARITY.md).

## Uso

1. Escolher ou criar uma sessão na barra lateral. Cada sessão pode agrupar agentes de várias pastas. O menu no cabeçalho filtra projetos, sem escolher o destino da próxima tarefa.
2. No compositor do rodapé, escolher explicitamente a pasta cadastrada e o provedor. A pasta também pode ser cadastrada por esse menu ou ⌘O. Escrever e clicar **Iniciar** (⌘Return). Nome, sessão e isolamento ficam nas opções; a sessão de destino aparece no editor. Nome vazio gera um nome derivado da tarefa com sufixo único.
3. O reconhecimento da criação traz ID e data de criação. Quando o quadro recebe essa mesma identidade, abre sua aba. Falha de atualização não reinicia a tarefa. “Voltar ao quadro” cancela apenas a abertura automática, preservando o processo.
4. Clicar em cartão, resumo lateral, linha da lista, prévia da grade ou aba abre o agente. O terminal aceita interação direta; o compositor abaixo envia uma nova instrução a uma IA disponível. Em janela larga há um painel de contexto à direita.
5. Fechar a aba mantém o agente. **Encerrar**, no menu do agente, exige confirmação. **Retomar** aparece para sessões interrompidas. A grade é somente leitura e nunca redimensiona o holder.

Inbox e próxima intervenção ficam no menu da área de trabalho (⌘⇧I / ⌘⇧N). Abrir um item ativa sessão, projeto e painel correspondentes. Revisão, PR/CI, histórico, processos e exportação continuam disponíveis. Consumo só é consultado após ação explícita e confirmação; a lateral exibe o último valor dessa consulta em memória.

## Estado e envio

As abas usam `id` + `createdAtMs`. Reutilizar um número não seleciona outro agente. Sessão, filtro de projeto, abas e modo quadro/lista/grade ficam em `workspace-navigation.json`, com versão, limite, lock, releitura e gravação atômica. Arquivo inválido é preservado; redefinição explícita guarda backup. Carregamento incompleto ou falha do motor não é snapshot vazio e não apaga abas restauradas.

Rascunhos de novas tarefas e de instruções ficam somente em memória, separados por projeto/identidade. Trocar de projeto ou aba não envia nem apaga o texto. Encerrar o aplicativo perde esses rascunhos. Busca e pasta do compositor ficam somente em memória. A sessão usa a preferência global persistida; não há um destino de sessão oculto independente da lateral.

O botão de envio é a confirmação explícita do texto. O motor aceita um único payload literal de até 24.000 bytes, incluindo delimitadores de paste; recusa shell, worktree arquivado, identidade obsoleta e estados inadequados. LF/tab são permitidos, controles C0/C1 são recusados. Uma IA ocupada ou com pedido de aprovação deve ser acompanhada pelo terminal; o envio de prompt não substitui a aprovação do CLI.

O estado do provedor é observado, não bloqueado atomicamente com a escrita no PTY: o protocolo upstream não oferece Input condicional. Atualizações disponíveis no socket são avaliadas antes do envio, mas existe uma janela entre a última observação e o recebimento. O reconhecimento confirma transporte, sem comprovar processamento, sucesso ou aplicação da instrução. Erro/incerteza preserva o rascunho e nunca provoca retry automático.

## Origem e validação

O primeiro fluxo foi adaptado da revisão MIT `f66aa854313026870aaf57f65d26d9cbfbf32269`, que continua sendo a dependência executável. A interface atual também usa a referência MIT `1dc08a44bc7698dbabfca37730de7df572d6091f`, conforme [origem documentada](OCTO_NATIVE_PARITY.md). Não incorpora frontend web, imagens, fontes ou marca do Octo.

Modelos e navegação são testados com stores e processos controlados. O script `scripts/render-workspace-preview.sh` renderiza as views reais em NSHostingView fora do desktop, com motor e projetos fictícios isolados em `.build`. O controle do computador estava indisponível nesta sessão; não houve inspeção interativa do bundle atual. [Evidências atuais](OCTO_NATIVE_VALIDATION.md) distinguem renderização, testes e critérios manuais ainda abertos. A inspeção parcial de 2026-11-08 permanece registrada separadamente.
