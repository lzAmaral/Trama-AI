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
- Marco ativo: M2, integração SwiftUI + motor Rust. É autorizada a execução do sidecar local para inspeção de capacidades; a UI de agentes continua demonstrativa. Não iniciar agentes reais nesta etapa. Leia também [docs/ENGINE_INTEGRATION.md](docs/ENGINE_INTEGRATION.md).
- Preserve a dependência upstream fixada e os avisos de licença. Não reimplemente integrações de provedores em Swift sem uma necessidade demonstrada. O armazenamento do motor deve ser isolado no Trama.
- Não abra Hub/Peer sem revisar seus efeitos: o watcher upstream consulta uso automaticamente. Inspeção não deve ler credenciais, consultar rede ou iniciar holders.
- Use branches curtas por entrega e PRs com problema, mudança e evidências de validação. Em checkout compartilhado, somente o integrador troca a branch, faz commit e envia mudanças. Para branches simultâneas, use worktrees separados.
- Antes de integrar: `swift build`, `swift test` e `git diff --check`; para mudanças no motor, também build/test com `--manifest-path Engine/Cargo.toml`. Revise o diff completo e registre falhas e limitações do ambiente.
- Teste comportamentos relevantes e caminhos de erro, especialmente persistência e transições de estado. Evite testes que apenas reproduzem a implementação.
- Não inclua tokens, arquivos de credenciais ou dados pessoais no código, fixtures ou logs. Não execute ações destrutivas, publique releases ou altere configurações globais sem autorização compatível com a tarefa.
- Não copie código das referências sem revisar sua licença e registrar a origem. Referência de produto não equivale a dependência.
