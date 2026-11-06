# Roadmap do Trama

Os itens abaixo são critérios de aceite. Marque-os como concluídos somente após implementação e validação; a ordem pode mudar conforme o aprendizado.

## M1 — Base nativa e demonstração

- [x] Pacote Swift 6 compilável para macOS 14+, com interface SwiftUI.
- [x] Seleção de projetos e painel com seções de Agentes e Atividade.
- [x] Cadastro de uma pasta local como projeto, com tratamento de duplicidade e erro.
- [x] Persistência de projetos em JSON dentro de Application Support.
- [x] Agentes e atividade de exemplo explicitamente identificados como demonstração.
- [x] Testes do núcleo e da persistência, incluindo entradas inválidas e falhas de leitura.
- [x] Build e testes no CI macOS; instruções de execução e limites no README.
- [x] Quadro por status, filtros, busca, lista e detalhes de agentes demonstrativos.
- [ ] Revisão independente e verificação manual da interface.

Pendências conhecidas: verificação visual/manual da interface e coordenação de gravações entre múltiplas instâncias. Nesta versão, execute apenas uma instância por vez.

Este marco não inicia processos de agentes nem altera arquivos dos projetos cadastrados.

## M2 — SwiftUI + motor Rust (marco ativo)

A decisão é reutilizar o motor e suas integrações, mantendo a interface SwiftUI. O contrato atual e a matriz de capacidades estão em [ENGINE_INTEGRATION.md](ENGINE_INTEGRATION.md). As tarefas de implementação só são consideradas verificadas após os checks da entrega.

- [x] Definir dependência Rust fixada e contrato de inspeção, com origem/licença registradas.
- [x] Validar build/test do sidecar e inspeção real: provedores detectados e contagem de registros persistidos.
- [x] Validar cliente Swift com prazo, limite de saída e tratamento de processo/JSON inválido.
- [ ] Validar ação Motor na interface; manter separação entre diagnóstico real e quadro demonstrativo.
- [ ] Adaptar transporte contínuo do motor, sem consultas automáticas de uso/credenciais.
- [ ] Suportar o lifecycle de holders exigido pelo launcher.
- [ ] Validar iniciar, enviar entrada, receber saída e encerrar uma sessão com processo controlado.
- [ ] Validar um CLI real de ponta a ponta, com aprovações preservadas, estados reais e recuperação de erro.

A inspeção pode executar o sidecar local e criar seus diretórios privados. Ela não inicia agentes reais nem modifica projetos. A instalação do CLI e seu login continuam sob responsabilidade do usuário/provedor.

## M3 — Conectar as capacidades existentes

- [ ] Expor hooks, estados e subagentes do motor no quadro nativo.
- [ ] Implementar terminal nativo, entrada interativa e histórico com limites de retenção.
- [ ] Integrar sessões, recuperação e skills sem reescrever os adaptadores de provedores.
- [ ] Integrar worktrees, diff e merge com revisão explícita do contexto e das alterações.
- [ ] Ligar os demais provedores após testes de contrato e smoke por integração disponível.
- [ ] Avaliar consulta de uso com ativação explícita e acesso a credenciais revisado.
- [ ] Avaliar acesso por telefone separadamente; não habilitar túneis ou exposição remota por padrão.

Ter o código upstream disponível não comprova que essas capacidades estão conectadas ou testadas no Trama.

## M4 — Portfólio e distribuição

- [ ] Revisar acessibilidade, atalhos, estados vazios e erros de ponta a ponta.
- [ ] Documentar arquitetura, decisões e evidências de testes com exemplos reproduzíveis.
- [ ] Gravar uma demonstração com dados fictícios e funcionalidades reais claramente separadas.
- [ ] Definir empacotamento, assinatura, notarização e política de atualização antes de distribuir.

Cada marco deve gerar PRs pequenos, com responsabilidades e critérios de aceite definidos pelo integrador. A organização de agentes está em [ENGINEERING.md](ENGINEERING.md) e [../AGENTS.md](../AGENTS.md).
