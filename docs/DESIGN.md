# Direção visual

A partir de 2026-11-14, o usuário escolheu Octo como referência direta para o Trama. A prioridade é reproduzir sua composição e densidade com componentes nativos macOS, conforme [mapeamento de paridade](OCTO_NATIVE_PARITY.md).

- Superfícies pretas, níveis `#0a0b0c` e `#141718`, acento `#35fddc`; atenção em amarelo, conclusão em verde e interrupção em vermelho.
- Tipografia proporcional do sistema para títulos e conteúdo; monoespaçada para nomes de agentes, caminhos, números e terminal.
- Barra lateral de 248 pt, redimensionável: marca própria `Trama >`, sessões expansíveis e agentes, consumo consultado manualmente e utilidades na base.
- Abas globais no topo; abrir ou fechar aba não inicia nem encerra processos.
- Cabeçalho da sessão com resumo, filtro de projeto e modos Quadro, Lista e Grade. Busca em popover com ⌘F; controles administrativos no menu.
- Quatro colunas com rolagem vertical independente, atenção primeiro. Cartões compactos com nome, símbolo, idade real do registro, projeto, provedor, atividade e branch disponível.
- Compositor fixo no rodapé: texto, provedor, pasta explícita e opções de nome/sessão/worktree. Skills reais aparecem ao digitar `/`; o envio continua explícito.
- Terminal SwiftTerm/AppKit; painel lateral de contexto em janelas largas e controles roláveis em janelas compactas. A grade usa snapshots somente leitura, até seis por página.
- Estados trazem símbolos/texto além de cor. Demonstração é identificada e separada de dados reais. Não há tempos de estado, limites de plano ou testes inventados.

A interface usa SwiftUI e AppKit, sem WebView. Fontes, símbolos e controles são nativos; os tokens e a composição foram adaptados da fonte MIT do Octo, com origem e avisos preservados. A marca e o mascote do Octo não foram copiados.

A direção anterior, de 2026-11-08, foi orientada pela skill [unslop](https://heydamir.design/unslop), de Damir Sokolovsky, CC BY 4.0. Suas evidências permanecem no histórico; esta entrega segue a referência Octo escolhida pelo usuário.

Resultados atuais em [OCTO_NATIVE_VALIDATION.md](OCTO_NATIVE_VALIDATION.md). Renderização isolada não substitui interação real, VoiceOver ou desempenho do terminal.
