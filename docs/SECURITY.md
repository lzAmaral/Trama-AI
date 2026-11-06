# Segurança: estado atual e requisitos

O Trama adota execução e armazenamento locais como direção de arquitetura. Isso não equivale a isolamento completo, funcionamento offline dos provedores ou às garantias anunciadas pelo Octo. Os mecanismos futuros abaixo ainda precisam ser implementados e testados.

## O que existe hoje

O aplicativo cadastra pastas e grava identificador, nome e caminho em `~/Library/Application Support/Trama/projects.json`. Não modifica arquivos dos projetos nem configurações de ferramentas. A gravação é atômica; erros de leitura bloqueiam novas gravações na interface para preservar os dados existentes. O JSON não é um cofre de segredos e não tem criptografia própria.

A ação de inspeção executa o processo auxiliar `trama-engine`, com argumentos separados, prazo e limite de saída. Ele detecta executáveis dos provedores e conta registros persistidos em armazenamento próprio; essa contagem não indica agentes em execução. A abertura do armazenamento pode criar diretórios privados. Não inicia holders, abre servidor local, lê tokens, faz login, consulta rede ou atualiza o aplicativo. O build com Cargo pode baixar a dependência fixada e suas dependências; isso é distinto da inspeção em runtime. Agentes e atividades exibidos são demonstrações. O uso de uma única instância é necessário enquanto não houver coordenação de gravações concorrentes.

| Princípio da referência | Situação no Trama |
| --- | --- |
| Controle em `127.0.0.1` e porta aleatória | A inspeção usa pipes do processo filho; não existe servidor de controle do Trama. Holders do motor serão ligados apenas após validar o lifecycle e a autenticação existentes. |
| Token de 256 bits por agente | Ainda não implementado; será exigido se houver serviço local de controle. Token de autenticação não significa criptografia dos dados. |
| Não alterar configurações globais | Já respeitado pelo cadastro atual; futuras integrações devem manter esse requisito. |
| Conferir SHA-256 antes de atualizar | Ainda não existe atualizador. A distribuição precisará validar também a autenticidade da origem. |
| Credenciais somente em memória e para seu emissor | O aplicativo não lê credenciais hoje. Não há medidor de consumo autenticado implementado. |

## Limites da reutilização

A biblioteca do motor é uma dependência de código fixada, não uma garantia automática de segurança ou paridade de recursos. A inspeção atual usa `Store`, `Home` e detecção de executáveis; não usa `Hub`/`Peer`. No snapshot adotado, o watcher de `Hub` consulta uso automaticamente. Antes de integrá-lo, é necessário impedir acesso involuntário a credenciais/rede e definir ativação explícita para cotas.

A implementação deve usar um diretório exclusivo do Trama e não importar a configuração ou sessões de outra instalação silenciosamente. Não expor comandos de trust, bypass, merge ou acesso remoto só porque existem no protocolo upstream. O contrato atual permite somente `inspect`.

## Antes do primeiro agente real

- Iniciar o executável validado com `Process`, argumentos separados e diretório do projeto explícito. Não interpolar tarefas ou caminhos em comandos de shell.
- Deixar o login e as credenciais sob responsabilidade do CLI e dos mecanismos oficiais do provedor. Não copiar tokens para o JSON, mensagens, logs ou fixtures.
- Não ler arquivos de login para consultar cotas até existir uma integração oficial verificada para esse uso. Filtrar o ambiente herdado conforme o contrato do CLI e evitar repassar segredos de outros provedores.
- Aplicar hooks e opções apenas ao processo lançado quando o CLI suportar esse escopo. Não editar configurações globais silenciosamente.
- Preservar as aprovações do CLI. Texto produzido por um agente não autoriza ações, acesso adicional ou desativação de proteções.
- Limitar saída capturada e retenção de logs; tratar falhas, cancelamento e encerramento. Revisar logs antes de qualquer exportação.

Um CLI local pode enviar prompts e código ao seu provedor. A interface deve explicar o provedor escolhido e o alcance da execução; não anunciar que “nada sai da máquina” sem que isso seja verdadeiro para toda a integração.

## Se houver daemon ou serviço local

- Preferir socket local com permissões restritas ao usuário; se TCP for necessário, escutar somente em loopback. Porta aleatória reduz previsibilidade, mas não autentica o cliente.
- Autenticar toda operação de controle, inclusive WebSocket, com segredo independente por sessão/agente, gerado por CSPRNG com pelo menos 256 bits, comparação adequada e invalidação ao encerrar a sessão.
- Restringir leitura de qualquer segredo persistido ao usuário. Não expor tokens em URLs, argumentos visíveis de processo, logs ou eventos da interface.
- Validar a associação entre cliente, sessão e projeto. Rejeitar tokens ausentes, incorretos, expirados ou de outra sessão.
- Se houver clientes web/HTTP, validar origem e proteger operações contra requisições de páginas externas; CORS sozinho não substitui autenticação.
- Não expor o serviço na rede externa por padrão. Qualquer acesso remoto exigirá desenho e revisão próprios.

## Antes de distribuir atualizações

Definir assinatura do aplicativo, notarização e validação da identidade esperada do publicador. Um eventual atualizador deve verificar um manifesto autenticado, tamanho e hash do artefato antes da substituição, além de prever falha e recuperação. SHA-256 isoladamente verifica integridade em relação ao hash recebido; não prova quem publicou o arquivo.

## Critérios de aceite das integrações

- [ ] Argumentos com espaços e metacaracteres não são interpretados como shell.
- [ ] Execução e encerramento não alteram configurações globais.
- [ ] Solicitações de aprovação não são aceitas automaticamente.
- [ ] Logs, erros e persistência não revelam segredos em cenários de teste.
- [ ] Cancelamento, falha do processo e saída excessiva são tratados.
- [ ] Se houver IPC: conexão externa, origem indevida e tokens inválidos são rejeitados; sessões não controlam outras sessões.
- [ ] Se houver atualização: manifesto/artefato adulterado e assinatura inesperada são rejeitados; falha preserva uma instalação utilizável.

Esses itens são requisitos de evolução, não verificações já concluídas. Os critérios gerais estão em [ENGINEERING.md](ENGINEERING.md) e a sequência de entrega em [ROADMAP.md](ROADMAP.md).
