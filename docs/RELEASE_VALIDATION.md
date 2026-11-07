# Evidências para fechar a versão

Build e testes automatizados são necessários, mas não fecham os critérios externos do roadmap. Registre a versão do aplicativo, macOS, arquitetura, Swift, Rust e revisão do motor junto de cada resultado. Não inclua prompts privados, credenciais, identificadores de conta ou histórico real nos relatórios.

## Interface e bundle

Abra o bundle produzido por `scripts/package-app.sh` e percorra: primeira execução, falha de leitura dos projetos, demonstração, quadro real vazio, busca sem resultados, lista/quadro, cadastro de pasta, diagnóstico e falha do motor. Verifique foco e ordem de teclado, atalhos, leitura dos controles com VoiceOver, legibilidade e redimensionamento da janela.

Use uma pasta temporária e o provedor **terminal** para conferir entrada, copiar/colar voluntário, resize, saída intensa, histórico e encerramento. Feche e reabra a janela para verificar que o holder continua existindo; encerre-o pelo controle do aplicativo ao terminar. Para worktree e merge, use um Git temporário, nunca o checkout de desenvolvimento ou um projeto do usuário. Uma captura estática não comprova interação, acessibilidade ou desempenho.

Grave a demonstração somente com dados fictícios identificados. Revise a gravação antes de compartilhá-la. A gravação, a revisão do bundle e a revisão de acessibilidade têm resultados separados; nenhum deles é substituído por `swift build`.

## Provedores autenticados

Cada provedor instalado precisa de uma execução manual própria. Detectar seu executável não confirma login, protocolo ou compatibilidade. O usuário escolhe a conta e inicia no aplicativo uma tarefa curta em pasta temporária; isso pode consumir créditos. Registre apenas provedor/versão, resultado da tarefa, pedido de aprovação observado, entrada no terminal, interrupção e recuperação quando suportada.

Consumo é outro teste: o usuário escolhe o provedor e aciona **Consultar agora**, após ler o aviso sobre credenciais e rede. Confira resultado ou erro compreensível; não copie credenciais nem respostas privadas para fixtures. Uma falha de autenticação não deve ser registrada como consulta validada. A execução de testes automatizados não autoriza essas consultas.

## Distribuição

O bundle local ad hoc serve para desenvolvimento. Developer ID, notarização e verificação Gatekeeper em outra máquina exigem identidade e configuração de distribuição disponíveis. Não criar certificados, buscar senhas, enviar à Apple ou publicar automaticamente para satisfazer um checkbox.

Uma distribuição deve acompanhar os avisos das dependências efetivamente incluídas. O inventário deve informar o target, a origem dos textos e qualquer cobertura faltante. Metadados SPDX sozinhos não substituem os avisos exigidos.

O Trama ainda não instala atualizações automaticamente. Um atualizador futuro deve validar origem e integridade antes de executar qualquer artefato: canal HTTPS autenticado, manifesto assinado com chave de confiança distribuída pelo aplicativo, identificação de versão/arquitetura e verificação da assinatura Developer ID esperada. Rotação/revogação de chave e falhas de atualização precisam de contrato e testes próprios. Em falha de verificação, preserve a instalação atual e informe o erro; hash recebido do mesmo servidor não autentica o editor. Nenhum mecanismo de atualização deve ativar silenciosamente provedores, migrar credenciais ou encerrar holders.

Para a avaliação de acesso remoto, veja [REMOTE_ACCESS.md](REMOTE_ACCESS.md).
