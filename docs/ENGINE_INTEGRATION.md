# Integração do motor

## Decisão

A interface permanece nativa em SwiftUI. O motor e as integrações existentes são reutilizados por um executável Rust auxiliar, `trama-engine`, compilado contra a biblioteca `orkai` do projeto Octo. Swift conversa com esse processo por entrada/saída padronizada, usando mensagens JSON versionadas e argumentos separados, sem comandos interpolados em shell.

A dependência está fixada no commit `f66aa854313026870aaf57f65d26d9cbfbf32269` (versão upstream `0.2.19`) em `Engine/Cargo.toml`. Não criamos um fork no GitHub nesta etapa nem copiamos as integrações para Swift. O Cargo baixa e compila a revisão fixada. Uma futura correção necessária no motor deve ser pequena, rastreável e revisada antes de atualizar essa referência.

A origem técnica e a licença ficam na documentação e em [Octo-MIT.txt](../ThirdPartyNotices/Octo-MIT.txt). A interface do produto usa a identidade Trama. O inventário de licenças das dependências transitivas continua necessário antes de distribuir o aplicativo.

## O que está conectado agora

O comando `trama-engine --inspect --home DIRETORIO_ABSOLUTO` usa `Store::open(Home::at(...))`, `Config::default()` e `launch::installed_kinds`. Retorna um objeto JSON com:

| Campo | Significado |
| --- | --- |
| `protocol` | Versão do contrato do Trama: `1` |
| `engine` | Identificador técnico da origem: `octo` |
| `upstreamRevision` / `upstreamVersion` | Revisão e versão fixadas |
| `providers` | Registro de provedores, com `id` e `installed` |
| `agentCount` | Quantidade de registros persistidos; **não** processos ativos |
| `operations` | Operações disponíveis nesta versão: somente `inspect` |

A ação **Motor** da interface consulta esse diagnóstico por um cliente Swift com prazo de execução e limite de saída. Detectar um CLI instalado não comprova autenticação, disponibilidade de conta ou compatibilidade integral da versão instalada.

A inspeção pode criar os diretórios privados do motor no caminho informado. Não abre `Hub`, conecta holders, inicia agentes, lê credenciais ou consulta cotas pela rede. O armazenamento pertence ao Trama; não há descoberta nem migração automática dos dados existentes do Octo. O build inicial com Cargo requer rede para baixar o código e as dependências; isso é separado da operação de inspeção em runtime.

## Reaproveitamento e implementação nativa

| Capacidade | Disponível no motor fixado | Ligação com o Trama |
| --- | --- | --- |
| Registro e detecção de CLIs | `model::AgentKind`, `launch::installed_kinds` | Conectada à inspeção |
| Armazenamento de registros | `Store` e `Home` | Contagem isolada, sem sessões reais na UI |
| Iniciar, enviar entrada e parar agentes | `Launcher`, `holder`, `client` | Pendente: contrato, lifecycle e controles nativos |
| Hooks, status e subagentes | `hooks`, `holder`, `subagents`, `Hub` | Pendente: eventos reais e recuperação de falhas |
| Terminal e histórico | PTY, snapshots e saída dos holders | Pendente: renderização e entrada nativas |
| Skills e sessões | `skills`, ações do `Peer` e `Store` | Pendente: adaptação de comandos e telas |
| Worktrees, diff e merge | `worktree` e ações do motor | Pendente: revisão, contexto e confirmação na UI |
| Consumo e cotas | `usage` | Desativado nesta etapa; futura ativação explícita após revisão |
| Telefone e acesso remoto | Módulos PWA/pairing | Etapa posterior; não iniciado pelo Trama |
| Atualizações | Código upstream e wrappers desktop | Etapa posterior; não reutilizar automaticamente o atualizador de outro produto |

Disponibilidade no código não significa paridade entregue. O motor conserva implementações úteis, mas cada capacidade precisa de contrato de transporte, mapeamento de estados, interface e testes no Trama.

## Próxima entrega: uma sessão real de ponta a ponta

1. Adaptar `Peer`, `PhoneMsg`, `BridgeMsg` e `Outbox` para um canal contínuo local; publicar capacidades e validar a versão do contrato.
2. Implementar o despacho interno esperado pelo launcher (`__holder`, `__agents`, `__hook`) ou um executável de holder dedicado. O launcher prepara uma cópia do seu executável; apenas aceitar JSON no sidecar não basta.
3. Antes de abrir `Hub`/`Peer`, controlar explicitamente a consulta de uso. O watcher upstream chama `refresh_usage` automaticamente; ativá-lo inadvertidamente poderia acessar credenciais e rede.
4. Validar iniciar, receber saída, enviar entrada e encerrar com um processo de teste controlado, em diretório temporário, sem autenticação de provedor.
5. Integrar um CLI real, preservando suas aprovações, e mostrar estados de erro/interrupção além das quatro colunas demonstrativas.
6. Só então ligar o restante das capacidades do motor, preservando testes e evitando reimplementar os adaptadores de provedores em Swift.

Fixar a revisão limita mudanças inesperadas, mas não elimina manutenção. Atualizações upstream exigem revisar protocolo, flags dos CLIs, layout de persistência e testes de contrato. O processo auxiliar facilita isolamento de falhas; não transforma automaticamente a execução de agentes em sandbox.
