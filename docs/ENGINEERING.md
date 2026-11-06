# Critérios de engenharia

“Padrão ouro” é uma meta comprovada por evidências, não um rótulo obtido pela linguagem, pelo número de agentes ou pela aparência da interface. Uma entrega deve ser simples de executar, revisável e explícita sobre o que ainda não faz.

## Base técnica

O primeiro marco é um pacote Swift 6 para macOS 14+, com executável SwiftUI e um núcleo testável sem dependência de interface. As views apresentam estado e encaminham intenções; o núcleo concentra modelos, validação e persistência. Não é necessário criar camadas sem uma responsabilidade concreta.

Projetos são armazenados em JSON local dentro de Application Support. O armazenamento deve ser injetável para testes com diretórios temporários. Diferencie a primeira execução de falhas de leitura e dados inválidos; não sobrescreva silenciosamente um arquivo corrompido. Grave de forma atômica e preserve o estado anterior quando uma operação falhar.

Dados de demonstração devem aparecer como demonstração na interface e permanecer separados dos projetos cadastrados pelo usuário. No modo real, tarefas iniciadas pelo usuário executam CLIs e podem acessar serviços dos provedores. Testes automatizados usam processos controlados, sem chamadas de IA pagas.

## Evidências por entrega

| Critério | Evidência esperada |
| --- | --- |
| Build reproduzível | `swift build` com versão do Swift documentada |
| Comportamento correto | `swift test` cobrindo os fluxos alterados e falhas relevantes |
| Persistência confiável | Testes de leitura/gravação, duplicidade e arquivo inválido |
| Interface compreensível | Verificação manual de estados vazio, carregado e erro; teclado e legibilidade |
| Mudança revisável | Diff sem ruído, `git diff --check` e revisão independente |
| Limitações honestas | README e PR distinguem funcionalidade real, demonstração e pendências |

CI deve automatizar build e testes em macOS. A primeira configuração de CI só é considerada validada após uma execução bem-sucedida; arquivos YAML sozinhos não comprovam funcionamento. Verificação visual também não é substituída por compilação.

## Desenvolvimento com agentes

Os **agentes de desenvolvimento** colaboram para construir este repositório. Os **agentes do produto** serão os processos que o Trama acompanha e controla. A capacidade de usar agentes durante a construção não significa que a integração no aplicativo já esteja implementada.

O fluxo de uma entrega é: integrador define uma tarefa pequena → responsáveis implementam partes independentes → outro agente revisa → integrador corrige e executa os checks → PR registra resultado e limites. Use paralelismo quando reduzir dependências e tempo de espera; evite múltiplos agentes alterando os mesmos arquivos.

Cada tarefa deve conter:

```text
Objetivo:
Arquivos sob responsabilidade:
Contrato de entrada e saída:
Dependências:
Critérios de aceite:
Validação executada e limitações:
```

## Integrações

Antes de executar o primeiro CLI, valide seu protocolo e ciclo de vida em uma tarefa específica. Use executável e argumentos separados, sem interpolar comandos em um shell. Trate cancelamento, encerramento, saída incompleta e limites de captura. Credenciais devem permanecer nos mecanismos do provedor ou armazenamento apropriado, nunca no JSON de projetos.

Não permita que conteúdo produzido por um agente transforme-se automaticamente em comandos ou autorizações. A interface deve distinguir atividade, pedido de intervenção e decisão do usuário. Recuperação de sessões, isolamento por worktree, múltiplos provedores e distribuição assinada exigem validações próprias antes de serem anunciados.
