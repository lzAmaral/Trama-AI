# Trabalho no Trama

Leia [docs/ENGINEERING.md](docs/ENGINEERING.md) e o marco ativo em [docs/ROADMAP.md](docs/ROADMAP.md) antes de alterar código.

## Coordenação

- O agente principal é o integrador: define escopo, contratos, responsáveis e critérios de aceite; resolve conflitos e comunica o resultado.
- Cada tarefa deve declarar objetivo, arquivos sob responsabilidade, dependências e validação esperada. Um arquivo tem um responsável por vez.
- Execute em paralelo apenas tarefas independentes. Combine os contratos de tipos e serviços antes de dividir implementação entre agentes.
- Mudanças em contratos compartilhados passam pelo integrador. Não reverta trabalho alheio nem edite arquivos atribuídos a outro agente sem combinar.
- Peça a um agente diferente do autor para revisar comportamento, falhas e testes antes da integração. O integrador verifica as correções.
- Agentes entregam um resumo dos arquivos alterados, validações executadas e limitações. Não apresentam planos ou testes pendentes como concluídos.

## Implementação e entrega

- Swift 6, macOS 14 ou superior; SwiftUI na interface. Mantenha modelos e persistência independentes das views.
- O primeiro marco usa demonstrações identificadas e não executa agentes ou comandos externos.
- Use branches curtas por entrega e PRs com problema, mudança e evidências de validação. Em checkout compartilhado, somente o integrador troca a branch, faz commit e envia mudanças. Para branches simultâneas, use worktrees separados.
- Antes de integrar: `swift build`, `swift test` e `git diff --check`; revise o diff completo. Falhas e limitações do ambiente devem ser registradas.
- Teste comportamentos relevantes e caminhos de erro, especialmente persistência e transições de estado. Evite testes que apenas reproduzem a implementação.
- Não inclua tokens, arquivos de credenciais ou dados pessoais no código, fixtures ou logs. Não execute ações destrutivas, publique releases ou altere configurações globais sem autorização compatível com a tarefa.
- Não copie código das referências sem revisar sua licença e registrar a origem. Referência de produto não equivale a dependência.
