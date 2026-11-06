# Tarefas da integração

O integrador distribui estas tarefas entre agentes e controla Git. Cada tarefa deve produzir implementação, testes e revisão por outro agente; dependências abaixo precisam estar concluídas antes da integração.

| ID | Entrega | Dependências | Critério de aceite | Estado |
| --- | --- | --- | --- | --- |
| E01 | Biblioteca Rust fixada + inspeção | — | Build bloqueado pelo lockfile e detecção pelo código upstream | Concluído |
| E02 | Cliente Swift do motor | E01 | Contrato real, timeout, cancelamento, limites e erros testados | Concluído |
| E03 | Diagnóstico na interface | E02 | Consulta real separada da demo; inspeção visual manual | Implementado; visual pendente |
| E04 | Transporte contínuo + lifecycle interno | E01 | Processo controlado inicia, emite saída, recebe entrada e encerra; sem consultas automáticas de uso | Pendente |
| E05 | Estado real no quadro | E04 | Eventos atualizam cards; interrupção/erro não aparecem como sucesso | Pendente |
| E06 | Terminal nativo | E04 | PTY, resize, entrada e sequências ANSI validados; limites de histórico | Pendente |
| E07 | Primeiro provedor real | E05, E06 | Fluxo tarefa → aprovação → saída → encerramento validado com CLI instalado | Pendente |
| E08 | Sessões, recuperação, skills e demais provedores | E07 | Reutilizar módulos upstream e testar cada contrato exposto | Pendente |
| E09 | Worktrees, diff e merge | E07 | Operações isoladas e revisão explícita das alterações | Pendente |
| E10 | Consumo/cotas opcional | E07 | Ativação explícita, contrato oficial verificado e nenhum segredo em logs | Pendente |
| E11 | Empacotamento e distribuição | E08, E09 | Bundle, assinatura, notarização, avisos e atualização autenticada validados | Pendente |

E05 e E06 podem ser desenvolvidas em paralelo depois de estabilizar E04. E08, E09 e E10 podem ser divididas após E07. Nenhum agente deve alterar o contrato compartilhado sem alinhar com o integrador.

Para E04, o escopo inicial é um processo de teste controlado: provar o lifecycle do motor antes de ligar um agente autenticado. O plano técnico está em [ENGINE_INTEGRATION.md](ENGINE_INTEGRATION.md).
