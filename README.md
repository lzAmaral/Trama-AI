# Trama

**Seus projetos e agentes, em um só lugar.**

Um app nativo para macOS, desenvolvido em Swift.

## Proposta

Trama é um projeto de portfólio para organizar projetos de software e acompanhar agentes de IA em uma interface nativa para Mac.

O foco inicial é dar visibilidade ao trabalho dos agentes: o que está em execução, o que foi concluído e o que precisa da sua intervenção.

## Estado do projeto

Planejamento inicial. Este repositório contém a apresentação e o escopo proposto; o aplicativo ainda não foi implementado.

## Primeiro ciclo de desenvolvimento

- [ ] Criar a estrutura do aplicativo macOS com Swift e SwiftUI.
- [ ] Construir a navegação entre Projetos, Agentes e Atividade.
- [ ] Permitir cadastrar uma pasta local como projeto.
- [ ] Prototipar os estados de agentes com dados de demonstração.
- [ ] Integrar um primeiro agente de programação via CLI.
- [ ] Exibir uma linha do tempo com atividade e solicitações de intervenção.
- [ ] Persistir projetos e preferências localmente.

A integração com múltiplos provedores será considerada após validar o fluxo completo com o primeiro agente.

## Direção técnica

- **Plataforma:** macOS.
- **Linguagem:** Swift.
- **Interface:** SwiftUI, com AppKit quando necessário.
- **Arquitetura:** separar interface, modelos e integração com processos de agentes.

A versão mínima do macOS e os detalhes de execução, persistência e distribuição serão definidos na implementação inicial.

