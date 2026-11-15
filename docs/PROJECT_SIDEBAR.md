# Navegação por projeto

A lateral real apresenta projeto → sessão → agentes. Projetos cadastrados aparecem mesmo sem agentes. Uma sessão compartilhada aparece em cada projeto envolvido, mostrando somente os registros daquele projeto; worktrees usam o projeto original para agrupamento. Arquivados permanecem disponíveis pela opção do quadro, sem ocupar a árvore padrão.

Selecionar projeto limpa o filtro de sessão e abre seu quadro. Selecionar sessão dentro dele atualiza ambos os filtros atomicamente, preserva abas e rascunhos e não inicia, encerra ou move processos. O cabeçalho mostra o nome do projeto e, quando selecionada, a sessão. O seletor redundante de projeto no cabeçalho foi removido. O caminho da pasta aparece no compositor (abreviado com `~` no novo agente, completo no tooltip); detalhes do agente mantêm a pasta junto à próxima instrução, sem repeti-la no cabeçalho e no inspector.

O armazenamento upstream mantém sessões globais. Sessões vazias ou com agentes fora dos projetos cadastrados continuam acessíveis em “Outras sessões”. Criar uma sessão dentro de um projeto mantém o projeto selecionado e apresenta a sessão vazia ali; após a primeira tarefa, a associação vem do projeto dos agentes. Sem agentes, ao sair desse escopo a sessão continua em “Outras sessões”. Renomear ainda afeta a sessão global, não apenas um projeto.

Validação: testes de agrupamento e seleção cobrem sessão compartilhada, projetos vazios, arquivados, worktrees/symlinks, persistência, projeto inválido e navegação antes do primeiro polling/falha. Capturas offscreen usam dados fictícios; não substituem teste de foco, teclado e VoiceOver reais. Nenhum provedor pago é iniciado.

Build Swift e 160 testes passaram, incluindo integração com o motor compilado. Nove capturas isoladas foram geradas; a hierarquia foi inspecionada na janela compacta de 820 × 560. A região SwiftTerm permanece vazia na captura offscreen, como na validação anterior; o desenho do terminal não foi validado por essas imagens. `git diff --check` passou.

A revisão independente não encontrou bloqueadores. A confirmação de renomear explica o alcance em todos os projetos. O agrupamento ainda normaliza caminhos durante a consulta de apresentação; o custo com muitos projetos não foi medido nesta entrega.
