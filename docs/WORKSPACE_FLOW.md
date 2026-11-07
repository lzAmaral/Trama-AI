# Área de trabalho por projeto

Esta entrega responde a três perguntas na própria tela: qual projeto está ativo, quais agentes existem nele e para onde vai o próximo prompt. A hierarquia usa como referência as três capturas do Octo fornecidas pelo usuário: contexto no topo, quadro por estado, compositor fixo no rodapé e agentes abertos em abas no painel principal. Não usa o mascote.

## Uso

1. Selecionar uma pasta cadastrada na barra lateral. Nome e caminho aparecem no cabeçalho e no compositor; “Todos os projetos” é uma visão geral, sem destino implícito para criar tarefas.
2. Escrever a tarefa no compositor do rodapé, escolher um provedor instalado e clicar **Iniciar agente** (⌘Return). **Novo agente** (⌘N) volta ao quadro e focaliza esse campo. Nome, sessão e isolamento ficam em opções avançadas; nome vazio gera um nome reconhecível derivado da tarefa com sufixo único.
3. O reconhecimento da criação traz ID e data de criação do registro. Quando o quadro recebe essa mesma identidade, abre sua aba e o terminal. Falha de atualização não reinicia a tarefa. “Voltar ao quadro” cancela apenas essa abertura automática, preservando o processo.
4. Clicar no card ou na aba abre o agente no painel principal. Provedor, estado e pasta permanecem identificados. O terminal recebe interação direta; o compositor abaixo envia uma nova instrução a uma IA disponível.
5. Fechar a aba mantém o agente em execução. **Encerrar**, no menu do agente, é uma operação distinta com confirmação. **Retomar** aparece para sessões interrompidas.

Abrir um item da inbox ativa o projeto e o painel correspondentes, inclusive se o mesmo agente já estiver aberto. Intervenções, revisão, PR/CI, histórico, processos e exportação continuam acessíveis. Consultas de GitHub e consumo permanecem manuais.

## Estado e envio

As abas usam `id` + `createdAtMs`. Reutilizar um número não seleciona outro agente. Projeto, abas e modo quadro/lista ficam em `workspace-navigation.json`, com versão, limite, lock, releitura e gravação atômica. Arquivo inválido é preservado; redefinição explícita guarda backup. Carregamento incompleto ou falha do motor não é snapshot vazio e não apaga abas restauradas.

Rascunhos de novas tarefas e de instruções ficam somente em memória, separados por projeto/identidade. Trocar de projeto ou aba não envia nem apaga o texto. Encerrar o aplicativo perde esses rascunhos. Busca, filtros e sessão do compositor não são preferências persistidas nesta entrega.

O botão de envio é a confirmação explícita do texto. O motor aceita um único payload literal de até 24.000 bytes, incluindo delimitadores de paste; recusa shell, worktree arquivado, identidade obsoleta e estados inadequados. LF/tab são permitidos, controles C0/C1 são recusados. Uma IA ocupada ou com pedido de aprovação deve ser acompanhada pelo terminal; o envio de prompt não substitui a aprovação do CLI.

O estado do provedor é observado, não bloqueado atomicamente com a escrita no PTY: o protocolo upstream não oferece Input condicional. Atualizações disponíveis no socket são avaliadas antes do envio, mas existe uma janela entre a última observação e o recebimento. O reconhecimento confirma transporte, sem comprovar processamento, sucesso ou aplicação da instrução. Erro/incerteza preserva o rascunho e nunca provoca retry automático.

## Origem e validação

Referência: Octo, revisão `f66aa854313026870aaf57f65d26d9cbfbf32269`, especialmente [`desktop/ui/index.html`](https://github.com/lucasmarujo/octo/blob/f66aa854313026870aaf57f65d26d9cbfbf32269/desktop/ui/index.html), `js/agent.js`, `js/state.js` e [`LICENSE`](https://github.com/lucasmarujo/octo/blob/f66aa854313026870aaf57f65d26d9cbfbf32269/LICENSE). Licença MIT, copyright 2026 Lucas Marujo, revista antes da adaptação. A interface foi implementada em SwiftUI, sem copiar JavaScript, imagens, ícones ou marca. Os avisos upstream existentes permanecem no bundle e a revisão fixada não mudou.

Testes de apresentação exercitam o modelo usado pela interface com repositório e motor falsos temporários, além dos testes puros de navegação e testes Rust/Swift de envio. Não executam IA paga, contas, rede externa ou notificações reais. A ferramenta de controle do computador recusou o acesso ao Trama com “Computer Use was not approved to use Trama”; verificação visual, foco real, VoiceOver e interação em janela mínima permanecem pendentes de autorização e execução. Compilação e inspeção de layout por código não são evidência visual.
