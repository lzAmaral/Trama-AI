# Roadmap do Trama

## M1 — Base nativa

- [x] Swift 6 / macOS 14+, cadastro de projetos e persistência atômica.
- [x] Demonstração identificada, quadro/lista, busca e filtros.
- [x] Testes de persistência e erros; primeira execução de CI macOS validada.
- [ ] Revisão visual e acessibilidade.
- [ ] Coordenação do cadastro entre múltiplas instâncias.

## M2 — Motor Rust e sessões reais

- [x] Dependência fixada, licenças e inspeção local.
- [x] RPC Swift/Rust com prazos, limites e cancelamento.
- [x] Lifecycle de holders: shell real, entrada, snapshot, resize, stop e recuperação.
- [x] Quadro real por padrão, sessões e estados de falha.
- [x] Terminal SwiftTerm, histórico e descoberta de skills.
- [x] Worktree, diff e merge confirmado, testados com Git temporário.
- [x] Consulta de consumo manual, sem watcher automático.
- [ ] Smoke autenticado por provedor e validação da consulta de consumo real.
- [ ] Verificação manual da interface e desempenho com saída intensa.

Implementação não implica paridade completa com Octo. `nested` identifica um CLI aninhado, não toda a árvore de subagentes. [Contratos e limites](ENGINE_INTEGRATION.md) e [tarefas](TASKS.md) detalham o que foi entregue.

## M3 — Evolução de produto

- [ ] Árvore completa de subagentes e controles de orquestração adicionais.
- [ ] Renomear/mover sessões e arquivar worktrees com tratamento explícito de alterações.
- [ ] Política de retenção e exportação de logs com revisão de dados sensíveis.
- [ ] Medir transporte e avaliar stream contínuo para terminais de alta frequência.
- [ ] Avaliar acesso remoto separadamente, sem exposição automática.

## M4 — Portfólio e distribuição

- [x] Arquitetura, critérios de engenharia e workflow com responsáveis/revisão.
- [x] Script de bundle `.app` com recursos, motor e assinatura ad hoc.
- [ ] Demonstração gravada e revisão visual do bundle.
- [ ] Inventário completo de avisos transitivos para distribuição.
- [ ] Developer ID, notarização e política de atualização autenticada.

Os itens ainda abertos não devem ser anunciados como concluídos. Os critérios gerais ficam em [ENGINEERING.md](ENGINEERING.md) e [SECURITY.md](SECURITY.md).
