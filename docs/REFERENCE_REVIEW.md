# Avaliação das referências

Revisão estática realizada em 5 de novembro de 2026, lendo código, testes, manifests e documentação. Nenhum código das referências foi executado ou incorporado ao Trama. A avaliação é uma amostra, não uma auditoria completa de segurança nem uma confirmação de que os testes passam.

## Conclusão

Octo e Maestrum oferecem ideias úteis, mas não devem receber automaticamente o rótulo de “padrão ouro”. Octo apresenta evidências mais fortes de validação automatizada. Maestrum é uma referência diretamente relacionada a SwiftUI e à separação entre interface e gerenciamento de agentes, com lacunas de validação e pontos de atenção na superfície local de controle.

## Octo

Snapshot revisado: `f66aa854313026870aaf57f65d26d9cbfbf32269`.

- O [workflow de CI](https://github.com/lucasmarujo/octo/blob/f66aa854313026870aaf57f65d26d9cbfbf32269/.github/workflows/ci.yml) configura formatação, Clippy e testes em Linux, macOS e Windows, além de checks da interface e etapas de empacotamento. A configuração, por si só, não prova uma execução bem-sucedida.
- Os [testes de integração do holder](https://github.com/lucasmarujo/octo/blob/f66aa854313026870aaf57f65d26d9cbfbf32269/tests/holder_e2e.rs) verificam comportamento de processos, rejeição de token inválido, estados vindos de hooks e isolamento por worktree.
- O [holder](https://github.com/lucasmarujo/octo/blob/f66aa854313026870aaf57f65d26d9cbfbf32269/src/holder/mod.rs) autentica a conexão usando token e comparação em tempo constante.

Lição para Trama: transformar requisitos de ciclo de vida e isolamento em testes observáveis. O suporte amplo a provedores não precisa ser reproduzido no primeiro marco.

## Maestrum

Snapshot revisado: `43d72dffca46a32c75c22aeb1eeed4f862b734df`.

- A [documentação de arquitetura](https://github.com/gabrielgreco1/maestrum/blob/43d72dffca46a32c75c22aeb1eeed4f862b734df/docs/architecture/00-overview.md) separa aplicativo SwiftUI, daemon e biblioteca compartilhada, com eventos persistidos e projetados na interface.
- O [pacote compartilhado](https://github.com/gabrielgreco1/maestrum/blob/43d72dffca46a32c75c22aeb1eeed4f862b734df/shared/Package.swift) inclui um executável smoke para modelos. Não foram encontrados workflows de GitHub Actions nem targets convencionais de teste nos manifests revisados. Isso não demonstra cobertura de processos ou da interface.
- A [composição do daemon](https://github.com/gabrielgreco1/maestrum/blob/43d72dffca46a32c75c22aeb1eeed4f862b734df/daemon/Sources/MaestrumDaemon/main.swift) usa loopback `127.0.0.1:7777`, mas não instala autenticação nas rotas de controle revisadas. O [handler WebSocket](https://github.com/gabrielgreco1/maestrum/blob/43d72dffca46a32c75c22aeb1eeed4f862b734df/daemon/Sources/MaestrumDaemon/WebSocket/StreamHandler.swift) também declara não autenticar. Loopback limita exposição de rede, mas não estabelece identidade do cliente local.
- O [AppState](https://github.com/gabrielgreco1/maestrum/blob/43d72dffca46a32c75c22aeb1eeed4f862b734df/app/Sources/Maestrum/State/AppState.swift) concentra 2.416 linhas no snapshot; essa concentração merece atenção ao definir responsabilidades no Trama, embora tamanho sozinho não demonstre defeito.

Lição para Trama: aproveitar a separação de responsabilidades sem antecipar um daemon ou uma infraestrutura distribuída. Quando existir comunicação entre processos capaz de iniciar ou controlar agentes, estabelecer autenticação e autorização explícitas.

## Aplicação no Trama

1. Manter modelos e persistência testáveis sem SwiftUI.
2. Integrar um provedor real antes de generalizar para vários.
3. Cobrir falhas de leitura, gravação, cancelamento e encerramento inesperado.
4. Separar demonstrações de atividade real e documentar limitações.
5. Usar revisão independente e CI com evidências de execução.
6. Dividir trabalho entre agentes por contratos e arquivos, com integração centralizada.

Os critérios do projeto estão em [ENGINEERING.md](ENGINEERING.md); a sequência de entregas está em [ROADMAP.md](ROADMAP.md).
