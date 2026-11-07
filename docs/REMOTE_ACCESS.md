# Avaliação de acesso remoto

Decisão desta entrega: manter o Trama local. O sidecar recebe uma operação por stdin/stdout e os holders usam o IPC autenticado upstream por TCP em loopback (`127.0.0.1`, porta efêmera). Não há listener em interfaces remotas, túnel, bridge PWA ou descoberta remota habilitados pelo aplicativo. A inspeção e o quadro continuam independentes de credenciais e consultas de consumo.

O fluxo remoto upstream passa por componentes que esta integração deliberadamente não inicializa. Em particular, inicializar Hub/Peer também pode iniciar o watcher de consumo. Reaproveitar esses componentes exige revisar seus efeitos, autenticação e ciclo de vida antes de conectá-los à interface; a presença do código na dependência não demonstra segurança ou suporte no Trama.

Uma entrega remota precisa definir quem autoriza a conexão, qual máquina executa a tarefa e quais projetos ela pode acessar. Autenticar um cliente remoto não equivale a autorizar escrita no projeto ou aprovações do CLI. Entrada PTY, encerramento, merge, exportação de histórico e consulta de consumo continuam sendo capacidades distintas, com decisões explícitas do usuário. Conteúdo de terminal não pode conceder nenhuma delas.

Antes de implementar, o contrato deve cobrir pareamento revogável, transporte autenticado e cifrado, prazos, reconexão, repetição de mutações e atribuição da máquina responsável. Perda de contato deve aparecer como estado desconhecido; não prova encerramento nem autoriza reiniciar uma tarefa. Logs, caminhos, prompts e dados de consumo não devem ser transmitidos por padrão.

A validação deve usar duas máquinas ou ambientes independentes e processos controlados: cliente não pareado, revogação, perda de conexão durante mutação, reconexão com holder ainda ativo e recusa de operações fora do projeto autorizado. Sem essas evidências, não anunciar acesso remoto nem paridade com a aplicação upstream. Esta avaliação não altera configurações, firewall ou serviços locais.
