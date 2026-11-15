# Identidade do tecelão no aplicativo

Entrega local de 15/11/2026, branch `feat/weaver-overview`.

## Escopo e responsabilidade

Objetivo: aplicar a composição visual aprovada pelo usuário à interface nativa: mascote no cabeçalho, tipografia monoespaçada, fundo carvão, indicadores de estado e lista compacta agrupada por projeto.

O integrador é responsável por `Package.swift`, views em `Sources/TramaApp`, recurso PNG, preferência inicial de navegação em `TramaCore`, testes afetados e scripts de validação/empacotamento. A revisão independente foi feita pelo agente `review_weaver`, somente em leitura. Dependências: contratos existentes do motor, consulta de consumo já implementada e imagem aprovada. Não houve mudança no Rust nem no pin upstream.

Critérios de aceite: imagem presente no executável e no bundle; navegação e destinos do compositor preservados; lista com dados reais, demonstração identificada; consumo somente por ação explícita; build, testes, diff e capturas em diferentes tamanhos verificados.

## Comportamento

- Novas preferências, seleção de projeto/sessão e ação Visão geral abrem a lista. Preferências `board` e `grid` já gravadas continuam sendo decodificadas. Quadro e Grade continuam disponíveis.
- Contadores usam os mesmos agentes filtrados da lista. `done` aparece como “para revisar”; estados disponíveis, encerrados, interrompidos e desconhecidos entram em “outros estados”, com o estado específico disponível no ícone, descrição acessível e tooltip de cada linha.
- A coluna Tempo informa idade do registro, não tempo de execução medido. Exemplos sem timestamp mostram um traço.
- Consumo saiu da lateral para o cabeçalho. Em larguras menores, abre pelo botão Consumo. Sem consulta, aparece orientação, sem percentuais inventados. Consultar/atualizar abre o fluxo manual existente; a rede só é acessada em Consultar agora.
- O compositor mantém destino, provedor, sessão, rascunhos e aprovações existentes. A aparência ganhou bordas retas. Mensagens de estado vazio podem rolar em janelas pequenas.
- O PNG é carregado uma vez via AppKit. A resolução do recurso procura primeiro `Contents/Resources/Trama_TramaApp.bundle`, com fallback para SwiftPM em desenvolvimento. O empacotamento recusa gerar um app sem a imagem.

## Origem visual

`Sources/TramaApp/Resources/trama-weaver.png` é a imagem original criada com a ferramenta integrada ImageGen nesta conversa e aprovada pelo usuário em 15/11/2026. Não é uma extração do personagem da referência. Direção do prompt: pequeno tecelão digital em pixel art, capuz verde-menta `#35FDDC`, roupa carvão, rosto marfim, detalhe lavanda e fios entrelaçados; corpo inteiro, fundo transparente, sem texto. A imagem aprovada foi copiada sem alteração para o projeto.

A captura fornecida pelo usuário orientou a composição, e a segunda proposta gerada foi aprovada para implementação. Nenhum código ou personagem foi copiado dessas imagens. Os avisos MIT já existentes das adaptações Octo permanecem nos arquivos e em ThirdPartyNotices.

## Validação

Ambiente: Apple Swift 6.1.2, arm64, alvo mínimo macOS 14.

- `swift build`: passou.
- `swift test`: passou, 161 testes reportados; três testes opt-in de integração com binário Rust ficaram desabilitados sem `TRAMA_TEST_ENGINE_PATH`. Nenhum provedor pago foi iniciado.
- `python3 -m unittest discover -s scripts/tests -p test_tools.py`: 17 testes passaram, incluindo recurso ausente e preservação do bundle anterior.
- `./scripts/render-workspace-preview.sh --responsive`: 26 layouts auditados, em cinco tamanhos de 820×560 a 1920×1080, mais as duas capturas de demonstração. Inclui nomes longos, editores, erros, skills e lateral larga.
- `./scripts/render-workspace-preview.sh`: passou com fixture isolado; inclui visão geral, lista, quadro, grade, terminal, estado vazio e erro de armazenamento.
- O renderer agora também recusa crescimento silencioso da janela acima das dimensões solicitadas. Essa guarda identificou e permitiu corrigir o overflow nos estados de erro e vazio.
- Revisão independente e inspeção visual confirmaram imagem, alinhamento da lista e dimensões das capturas. Os testes de rollback continuam tentando uma mudança real (`list` → `grid`) antes da falha simulada.
- `./scripts/package-app.sh`: bundle local com assinatura ad hoc em `.build/Trama.app`; `codesign --verify --deep --strict` e `git diff --check` passaram.

Evidência versionada: [visão geral com dados fictícios](media/trama-weaver-workspace.png). Logs e demais capturas ficam em `.build/weaver-*.log` e `.build/octo-native-previews`.

Limites: renderização nativa isolada não substitui interação manual, VoiceOver ou validação autenticada de consumo. Na janela mínima com erros e rascunho longo, a área da lista/quadro é menor e exige rolagem. Mascote estático, sem animação. Esta entrega não publica release nem fornece notarização. Uma instância já aberta precisa ser reaberta para carregar o executável atualizado.
