# Piloto de supervisão e entrega

Objetivo: verificar se inbox, revisão de diff e vínculo PR/CI reduzem o esforço para acompanhar agentes e concluir uma entrega revisada. A instrumentação local prepara a coleta; não representa pesquisa já realizada nem substitui participantes reais.

## Participantes e execução

O usuário escolheu em 2026-11-07 testar primeiro sozinho. Depois dessa primeira sessão, avaliar um pequeno grupo de desenvolvedores que trabalham em mais de um projeto com agentes. O participante escolhe seu projeto e provedor, entende a possibilidade de consumo de créditos e decide se ativa a medição local. Não coletar repositórios privados, prompts ou código para comparar participantes.

Para a primeira sessão:

1. Abrir o bundle de validação e, em **Piloto e alertas**, decidir se participa da medição local. Alertas do macOS são uma escolha separada.
2. Criar uma tarefa pequena após ativar a medição, preferindo worktree isolada para revisar também commits feitos pelo agente. Anotar o resultado esperado antes de começar.
3. Usar **Inbox** e **Próximo item** (⌘⇧N) quando houver uma intervenção. Responder no terminal só quando necessário; conferir a distinção entre visto e entrada entregue.
4. Em **Alterações**, revisar um snapshot não vazio, salvar uma nota em linha de conteúdo e conferir a prévia antes de decidir enviá-la. Concluir a revisão explicitamente após verificar a versão atual.
5. Se já existir PR da mesma branch no mesmo repositório GitHub, usar **PR/CI** e autorizar uma consulta. Conferir HEAD, horário e eventuais alterações locais; a ausência de PR não bloqueia o piloto.
6. Voltar ao aplicativo em outro momento, preparar a exportação local se desejar e registrar as dificuldades observadas. Uma sessão prepara correções de usabilidade; não comprova retenção ou preço.

Propor uma tarefa pequena com critério de aceite claro. O participante inicia a sessão, acompanha uma intervenção se houver, revisa o diff, deixa um comentário e consulta a PR/CI quando existir uma PR correspondente. O teste deve admitir a ausência de bloqueio ou de PR; não forçar eventos apenas para preencher métricas. A pessoa pode usar somente terminal controlado para explorar a interface sem tarefas pagas; envio de revisão a shell é deliberadamente recusado.

Durante o uso, observar onde a pessoa procura os controles, o que interpreta como sucesso e quantas vezes precisa sair do Trama. Depois perguntar qual decisão a inbox ajudou a tomar, se a revisão manteve contexto suficiente e o que a faria usar o fluxo novamente. Exportar métricas somente por escolha explícita do participante e revisar o arquivo antes de compartilhá-lo.

## Indicadores

| Indicador | Definição | Limite de interpretação |
| --- | --- | --- |
| Tempo até a primeira entrega revisada | Criação de um agente após opt-in até o primeiro registro explícito de revisão de diff não vazio desse agente | Não mede aprovação, merge nem testes aprovados; agentes anteriores ao opt-in ficam fora |
| Tempo até abrir uma intervenção | Primeira observação da ocorrência pelo Trama até sua leitura explícita | Não significa resposta nem resolução; polling/offline alteram o início observado |
| Tempo até entrada entregue | Primeira observação de `paused` até uma entrada posterior cujo RPC de envio teve sucesso | Não comprova que o provedor processou ou aprovou a ação; entrada incerta/falha não conta |
| Retorno ao aplicativo | Visitas registradas na ativação, com intervalo mínimo de 30 minutos, e contagem de dias ativos UTC | Não é retenção validada com uma única pessoa ou uma sessão |
| Entregas revisadas | Primeira revisão explícita elegível por agente na janela de medição | Não contar repetidas revisões do mesmo agente como várias entregas independentes |

Agregados devem sempre apresentar sua contagem de amostras. Uma média sem ocorrências é indisponível, e não zero segundos. Não estimar desempenho, economia ou retenção a partir de eventos que não aconteceram.

## Decisão após o piloto

Comparar o relato com o comportamento observado: participantes encontraram os bloqueios, conseguiram revisar sem perder a versão e entenderam quando o CI era antigo? Priorizar correções dessas dificuldades antes de ampliar o escopo. Para estimar valor comercial, conversar sobre uso recorrente e disposição a pagar com base na experiência, sem deduzir isso de cliques ou velocidade de desenvolvimento.

Não foram definidos ganhos percentuais, preço, tamanho de mercado ou metas de retenção como resultados comprovados. Registrar quantidade de participantes, duração, cenários exercitados, amostras disponíveis e limitações ao relatar resultados reais.
