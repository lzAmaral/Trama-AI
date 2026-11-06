# Segurança e limites

O Trama executa CLIs locais e reutiliza o motor Rust fixado do Octo. Um CLI pode modificar o projeto e enviar código/prompts ao seu provedor. O aplicativo não é uma sandbox e não promete que todos os dados permanecem na máquina.

## Transporte e processos

Swift chama o binário com argumentos separados; solicitações JSON seguem por stdin, respostas por stdout. O cliente impõe prazos e limites, descarta stderr e não repete automaticamente mutações. Cancelar uma solicitação mata seu processo, não os holders iniciados por ela. Após timeout, consulte as sessões antes de repetir.

O motor reutiliza controle local autenticado dos holders upstream. O Trama não inicializa Hub/Peer ou bridge PWA, nem habilita túneis ou acesso remoto. A dependência fixada não substitui auditoria do IPC upstream; testes de lifecycle não comprovam resistência a todos os cenários de ataque local.

Iniciar tarefas mantém as aprovações do CLI: `bypass` e `remote_control` são falsos. A saída de um agente não é tratada como autorização para executar ações. Os callbacks OSC de clipboard, abertura de links e comandos do terminal não são encaminhados ao host; copiar/colar voluntariamente continua disponível.

## Dados

Projetos ficam em `~/Library/Application Support/Trama/projects.json`; registros, configuração de lançamento e logs do motor ficam em `~/Library/Application Support/Trama/Engine`. Não há importação silenciosa de outra instalação. O cadastro usa gravação atômica e bloqueia gravações após erro de leitura. Execute uma instância por vez: o lock de mutações do motor não protege o JSON de projetos entre apps.

Os dados não têm criptografia própria. Logs e tarefas podem conter conteúdo sensível produzido pelo usuário ou pelo CLI. A UI limita o histórico exibido e o motor limita replay, mas isso não garante redação de segredos nem limita todo o espaço ocupado. Não exporte logs automaticamente. A remoção de registro encerrado sem worktree apaga também seu histórico, preservando a pasta do projeto.

## Consumo e credenciais

Inspeção e atualização do quadro não consultam consumo. O watcher upstream que faria consultas automáticas não é iniciado. O login continua a cargo de cada CLI.

A tela de consumo informa que a consulta pode ler credenciais locais e enviar uma requisição ao serviço do provedor. Só o botão **Consultar agora** aciona `usage` com confirmação explícita; o motor rejeita requisições sem confirmação. Reutilizamos os adaptadores upstream sem copiar credenciais para o JSON de projetos, fixtures ou mensagens. Esta entrega não valida esses adaptadores com contas reais nem afirma que seus endpoints sejam APIs públicas estáveis. Revise os adaptadores ao atualizar o snapshot e antes de anunciar suporte de consumo a cada provedor.

O cancelamento do RPC não garante encerrar processos transitórios iniciados por adaptadores upstream, como Git, Keychain ou o CLI de consumo. Essa limitação precisa de supervisão adicional antes de distribuição. Alguns adaptadores aceitam destinos HTTPS configuráveis (Kilo/Kimi); revise a configuração do provedor antes da consulta.

O processo herda o ambiente do aplicativo para compatibilidade com CLIs. Isso pode incluir variáveis sensíveis; ainda não existe allowlist específica por provedor. Não execute código não confiável supondo isolamento entre provedores.

## Git

Worktree é opcional. Diff é apresentado como texto. Merge exige worktree, holder encerrado, mensagem não vazia, carregamento do diff e confirmação explícita; pode criar commits no projeto. Não há merge automático a partir da saída do agente. Remoção de registros com worktree é recusada para evitar descarte de alterações. Operações externas no repositório ainda podem concorrer com o app; reveja o estado se houver erro.

## Validação e distribuição

Testes cobrem transporte inválido/excessivo, cancelamento e timeout, solicitações literais, shell/PTY, recuperação, logs, worktree e merge em diretório temporário. Não executam agentes pagos, leitura autenticada de consumo ou mudanças em configuração global. Ainda faltam smoke autenticado por provedor, revisão visual e auditoria completa do IPC upstream.

O bundle local tem assinatura ad hoc. Não há Developer ID, notarização, instalador ou atualizador. Antes de distribuição pública, reunir todos os avisos das dependências incluídas, configurar identidade de assinatura e notarização e definir um canal de atualizações autenticadas. Um hash isolado não comprova a origem de um binário.
