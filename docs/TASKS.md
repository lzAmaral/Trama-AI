# Tarefas da integração

O integrador define contratos, delega arquivos exclusivos e integra após revisão cruzada. Testes de CLI autenticado e verificação visual são critérios separados da compilação.

| ID | Entrega | Dependências | Estado e evidência |
| --- | --- | --- | --- |
| E01 | Biblioteca Rust fixada + inspeção | — | Implementado; contrato real testado |
| E02 | Cliente Swift do motor | E01 | Implementado; JSON, prazos, cancelamento e limites testados |
| E03 | Diagnóstico nativo | E02 | Implementado; revisão visual manual pendente |
| E04 | RPC e lifecycle de holders | E01 | Implementado via requisições pontuais/polling; shell real testado sem Hub/Peer |
| E05 | Quadro real | E04 | Implementado; filtros, busca, estados lost/exited; revisão visual pendente |
| E06 | Terminal nativo | E04 | SwiftTerm, entrada, resize e snapshot; PTY testado; interação visual pendente |
| E07 | Execução de provedores | E05, E06 | Launcher conectado e aprovações preservadas; smoke autenticado de cada CLI pendente |
| E08 | Sessões, recuperação e skills | E04 | Implementado; recuperação testada; não inclui árvore completa de subagentes ou editor avançado de sessões |
| E09 | Worktrees, diff e merge | E04 | Implementado; shell + Git temporários, confirmação e bloqueio de agente vivo testados |
| E10 | Consumo opcional | E02 | Implementado manualmente; contrato e rejeição sem consentimento testados; endpoint/conta real por provedor pendentes |
| E11 | Empacotamento | E05, E06 | Script de bundle local ad hoc; distribuição Developer ID/notarizada e atualizador pendentes |

## Responsabilidades desta entrega

- Motor: RPC, lifecycle, validação e testes Rust.
- Transporte Swift: modelos, cliente e testes de contrato/integração.
- Terminal: SwiftTerm, revisão cruzada das views e bundle.
- Integrador: quadro/composer/detalhes/consumo, revisão do motor/cliente, documentação, checks e Git.

Arquivos compartilhados só mudam após alinhamento. Não há execução automática de tarefas pagas nos testes. Falhas de timeout não autorizam retry automático de mutações.

## Próximos critérios externos

1. Abrir o bundle e revisar teclado, acessibilidade, estados vazios/erro, seleção e redimensionamento com o usuário.
2. Validar tarefa curta em cada provedor instalado/autenticado, incluindo pedido de aprovação e interrupção.
3. Consultar consumo manualmente em cada conta que o usuário escolher e revisar o adaptador correspondente.
4. Configurar assinatura/notarização quando houver identidade de distribuição e reunir os avisos transitivos.

Acesso remoto, árvores completas de subagentes e atualizações automáticas exigem entregas próprias; não são recursos habilitados nesta versão.
