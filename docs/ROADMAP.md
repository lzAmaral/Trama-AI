# Roadmap do Trama

## M1 — Base nativa

- [x] Swift 6 / macOS 14+, cadastro de projetos e persistência atômica.
- [x] Demonstração identificada, quadro/lista, busca e filtros.
- [x] Testes de persistência e erros; primeira execução de CI macOS validada.
- [ ] Revisão visual e acessibilidade.
- [x] Rótulos de acessibilidade, atalhos e estados de carregamento/erro revisados em código; VoiceOver real continua pendente.
- [x] Coordenação do cadastro entre múltiplas instâncias com lock e releitura antes de gravar.

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
- [x] Medição reproduzível do transporte com saída intensa e processos controlados, sem renderização da UI.

Implementação não implica paridade completa com Octo. `nested` identifica um CLI aninhado, não toda a árvore de subagentes. [Contratos e limites](ENGINE_INTEGRATION.md) e [tarefas](TASKS.md) detalham o que foi entregue.

## M3 — Evolução de produto

- [x] Inbox de intervenções, comentários versionados no diff e vínculo manual com PR/CI — revisão cruzada e testes com processos controlados.
- [x] Instrumentação local opt-in e [roteiro de piloto](PILOT.md), com exportação agregada sem conteúdo.
- [ ] Executar o primeiro piloto com o usuário e registrar resultados; verificação visual, alertas macOS e integração autenticada continuam pendentes.
- [x] Parentesco de registros e consulta limitada de descendentes locais, sem argumentos/ambiente de processos.
- [ ] Árvore lógica completa de subagentes e controles de orquestração adicionais por provedor.
- [x] Renomear sessões, mover registros encerrados e arquivar worktrees no lugar, preservando alterações e branch.
- [x] Retenção manual e exportação de logs com prévia, revisão de dados sensíveis e confirmação.
- [x] Medir transporte e avaliar stream contínuo: manter RPC nesta entrega; medir interação/renderização antes de mudar a arquitetura.
- [x] Avaliar acesso remoto separadamente, sem exposição automática; decisão e critérios em [REMOTE_ACCESS.md](REMOTE_ACCESS.md).

Arquivamento não libera disco e não tem desarquivamento nesta entrega. Retenção não é automática nem uma quota global. Árvore de processos e parentesco registrado não comprovam completude de subagentes do provedor. Evidências e limites ficam em [ENGINE_INTEGRATION.md](ENGINE_INTEGRATION.md) e [scripts/VALIDATION.md](../scripts/VALIDATION.md).

## M4 — Portfólio e distribuição

- [x] Arquitetura, critérios de engenharia e workflow com responsáveis/revisão.
- [x] Script de bundle `.app` com recursos, motor e assinatura ad hoc.
- [ ] Demonstração gravada e revisão visual do bundle.
- [x] Inventário reproduzível com textos e origens, verificado para ambos os targets macOS.
- [ ] Revisão final dos avisos e fontes exigidos para distribuição pública; duas ausências Windows permanecem explícitas fora dos grafos macOS.
- [x] Ferramenta opt-in de preparação Developer ID/notarização, testada com fixtures sem certificados ou envio à Apple.
- [ ] Developer ID, notarização real e validação Gatekeeper em outra máquina.
- [x] Política de confiança para um futuro canal de atualizações documentada; o aplicativo não instala atualizações automaticamente.

Os itens ainda abertos não devem ser anunciados como concluídos. Os critérios gerais ficam em [ENGINEERING.md](ENGINEERING.md) e [SECURITY.md](SECURITY.md).

Em 2026-11-07, a ferramenta de controle do computador recusou acesso ao Trama. A revisão visual, VoiceOver e gravação continuam pendentes. Smoke de provedores e consumo dependem das contas escolhidas pelo usuário; Developer ID/notarização dependem da configuração de distribuição. Veja [RELEASE_VALIDATION.md](RELEASE_VALIDATION.md).
