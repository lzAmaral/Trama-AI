# Roadmap do Trama

Os itens abaixo são critérios de aceite. Marque-os como concluídos somente após implementação e validação; a ordem pode mudar conforme o aprendizado.

## M1 — Base nativa e demonstração

- [x] Pacote Swift 6 compilável para macOS 14+, com interface SwiftUI.
- [x] Seleção de projetos e painel com seções de Agentes e Atividade.
- [x] Cadastro de uma pasta local como projeto, com tratamento de duplicidade e erro.
- [x] Persistência de projetos em JSON dentro de Application Support.
- [x] Agentes e atividade de exemplo explicitamente identificados como demonstração.
- [x] Testes do núcleo e da persistência, incluindo entradas inválidas e falhas de leitura.
- [ ] Build e testes no CI macOS; instruções de execução e limites no README.
- [ ] Revisão independente e verificação manual da interface.

Pendências conhecidas: verificação visual/manual da interface e coordenação de gravações entre múltiplas instâncias. Nesta versão, execute apenas uma instância por vez.

Este marco não inicia processos de agentes nem altera arquivos dos projetos cadastrados.

## M2 — Primeiro agente real

- [ ] Escolher um CLI e documentar o protocolo validado, versão e requisitos de instalação.
- [ ] Implementar um adaptador com executável e argumentos separados, sem interpolação de shell.
- [ ] Iniciar uma sessão vinculada a um projeto e acompanhar saída e encerramento.
- [ ] Exibir estados reais e erros, sem inferir sucesso apenas por silêncio no terminal.
- [ ] Cancelar sessões e lidar com processo interrompido ou protocolo inválido.
- [ ] Testar integração com um processo controlado e fazer um teste manual com o CLI escolhido.

## M3 — Trabalho supervisionado

- [ ] Linha do tempo por sessão com eventos estruturados e limites de retenção.
- [ ] Solicitações de intervenção e aprovação com contexto suficiente para decisão.
- [ ] Recuperação de sessão com semântica documentada para fechar/reabrir o aplicativo.
- [ ] Revisão de alterações e isolamento por worktree quando houver edição concorrente.
- [ ] Segundo provedor, apenas após estabilizar o contrato do primeiro.

## M4 — Portfólio e distribuição

- [ ] Revisar acessibilidade, atalhos, estados vazios e erros de ponta a ponta.
- [ ] Documentar arquitetura, decisões e evidências de testes com exemplos reproduzíveis.
- [ ] Gravar uma demonstração com dados fictícios e funcionalidades reais claramente separadas.
- [ ] Definir empacotamento, assinatura, notarização e política de atualização antes de distribuir.

Cada marco deve gerar PRs pequenos, com responsabilidades e critérios de aceite definidos pelo integrador. A organização de agentes está em [ENGINEERING.md](ENGINEERING.md) e [../AGENTS.md](../AGENTS.md).
