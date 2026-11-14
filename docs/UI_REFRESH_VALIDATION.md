# Validação do redesign da área de trabalho

Entrega local de 2026-11-08, branch `feat/workspace-ui-refresh`. Escopo: apresentação SwiftUI, sem alterações no núcleo, persistência, RPC, dependência upstream ou permissões dos provedores.

## Ambiente e checks

- macOS 26.6.2 (25G83), Apple Silicon / arm64.
- Apple Swift 6.1.2; pacote em modo Swift 6, destino mínimo macOS 14.
- `swift build`: passou, inclusive após as correções da revisão.
- `swift test`: passou; resumo do runner: 132 testes em 17,752 s. Três testes de integração opt-in foram ignorados: `swiftCommunicatesWithTheCompiledRustEngine`, `swiftControlsARealShellAcrossRequestProcesses` e `compiledEngineReviewAndCancellationLeaveTheHolderAlive`.
- `git diff --check`: passou.
- `scripts/package-app.sh`: passou, incluindo build Rust fixado com `--locked`, build Swift, recursos e verificação de assinatura ad hoc. Bundle final em `.build/Trama.app`.
- Nenhum código Rust foi alterado; a suíte Cargo não foi repetida nesta entrega de interface.

## Inspeção do aplicativo

A ferramenta de controle do computador conseguiu acessar o Trama nesta sessão. A versão anteriormente aberta era anterior ao checkout; foi comparada com o bundle redesenhado. O bundle principal foi atualizado e reaberto ao final, com a demonstração desligada e a janela restaurada ao tamanho de trabalho.

Conferidos por interação e árvore de acessibilidade:

- Projeto selecionado, caminho de destino e contagem de agentes.
- Quadro carregado, com colunas no topo e cartões de tarefa.
- Busca sem resultados e retorno ao quadro ao limpar a busca.
- Alternância entre quadro e lista.
- Abertura de aba existente, identificador visível e retorno à visão geral.
- Ativação da demonstração, quatro cartões identificados como exemplos, abertura/fechamento dos detalhes e retorno aos dados reais.
- Opções de nome, sessão e worktree acessíveis no popover; Escape retorna ao campo da tarefa.

Conferidos visualmente por capturas da janela: hierarquia e espaçamento em janela ampla; janela compacta obtida com o comando nativo de mosaico, aproximadamente 821 × 613 pt incluindo a barra de título. Na primeira versão, expandir opções eliminava a área do quadro. Após mover as opções para o popover e compactar o compositor, uma nova captura confirmou espaço para quadro e controles de início na janela compacta. O quadro mantém rolagem horizontal para suas quatro colunas.

Não foram salvas capturas, nomes de projetos, prompts ou históricos reais no repositório. Não foram iniciadas novas tarefas de IA, consultas de consumo, alterações de worktree ou operações de Git pelo aplicativo. As interfaces foram reiniciadas sem encerrar o holder existente; o agente voltou a aparecer ativo no bundle final.

## Revisão independente

Outro agente revisou o diff de todos os sete arquivos Swift, sem ser autor das mudanças. Encontrou e verificou a correção de dois problemas:

1. Tarefas repetidas ficavam indistinguíveis nas abas e no detalhe: o identificador passou a ficar visível.
2. Aprovação pendente e sessão interrompida ficavam iguais na lista: o estado textual foi restaurado e os símbolos diferenciados.

A segunda revisão também verificou os bindings, bloqueios de criação e validações preservados no popover de opções. Nenhuma nova regressão concreta foi apontada na revisão estática.

## Limites

Esta entrega não fecha toda a revisão manual do roadmap. Não foram exercitados VoiceOver, erro de leitura dos projetos, falha do motor, provedores ausentes, múltiplos avisos simultâneos na janela mínima, cadastro de nova pasta nem desempenho com saída intensa. O estado vazio por busca foi exercitado; a primeira execução sem projetos não foi simulada no armazenamento real. Testes autenticados por provedor e testes de execução continuam separados da revisão de apresentação.
