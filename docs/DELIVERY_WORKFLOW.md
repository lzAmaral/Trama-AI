# Supervisão e revisão de entregas

Esta entrega conecta inbox de intervenções, comentários no diff e consulta de PR/CI. A implementação é dividida em núcleo Swift testável, operações locais do sidecar e apresentação SwiftUI; a revisão independente precede a integração. Não substitui a validação com participantes reais do piloto.

## Contratos de produto

A inbox usa identidade composta por ID e data de criação do registro do motor. Um ID reutilizado não herda intervenções, comentários ou vínculos de outro agente. Cada home do motor tem armazenamento próprio. Ausência de timestamp impede rastreamento nessa entrega, em vez de adivinhar identidade.

`paused` cria um pedido de atenção, sem afirmar que seja aprovação de permissão. `lost` indica interrupção observada. Uma transição conhecida para `done` disponibiliza revisão; a primeira leitura de uma sessão já concluída não inventa uma nova entrega. `exited` é encerramento, sem inferir sucesso. Falha de atualização, estado desconhecido e desaparecimento não resolvem intervenções automaticamente.

Visto, entrada entregue ao terminal e resolução são fatos distintos. Abrir um item marca sua leitura, preservando as aprovações do CLI. Intervenções de revisão permanecem pendentes até registro explícito de revisão ou dispensa. Falhas de checks consultadas pelo usuário também entram na inbox, vinculadas à PR e ao HEAD observado; uma reconsulta não deve duplicar a mesma ocorrência. Pending ou ausência de informação não comprovam correção de uma falha.

## Comentários e envio

O snapshot de revisão usa diff sem ANSI, textconv ou comando externo de diff, com limite explícito e sem truncamento silencioso. A versão cobre a identidade do agente, o contexto Git pertinente e os bytes do diff. As âncoras são linhas de conteúdo de hunks, numeradas a partir de 1 no snapshot exibido. Cabeçalhos e marcadores fora desses hunks não são comentários de linha.

Em worktree isolada, o diff inclui mudanças desde a base registrada, mesmo depois de commits do agente. Sem isolamento, compara os arquivos com o HEAD atual e inclui arquivos untracked; commits já incorporados ao HEAD não aparecem como alterações pendentes. Não há inferência de um commit inicial de tarefa sem worktree. Arquivos ignorados não entram na revisão.

Comentários persistem por versão. Um novo diff não desloca silenciosamente uma observação para outra linha. A interface mantém notas antigas identificadas e permite revisitar seus registros. Registrar uma revisão revalida a versão exibida; essa ação declara revisão humana, sem afirmar aprovação dos testes ou do código.

Preparar o lote produz texto e token da prévia no motor. Após confirmação explícita, o motor compara identidade, versão, token e notas antes de enviar os mesmos bytes de texto. O destino precisa ser um provedor de IA vivo em estado adequado de prompt; terminal/shell, CLI aninhado divergente, agente trabalhando, pedido de intervenção ou registro arquivado são recusados. A prévia não inicia uma tarefa. O envio pode iniciar trabalho no provedor e consumir créditos, conforme a ação do usuário.

O recebimento pelo PTY não comprova processamento do provedor. Não há retry automático; timeout ou cancelamento pode deixar o resultado incerto e exige verificar a sessão antes de tentar novamente. Uma edição concorrente da nota não deve ser marcada como enviada por um lote anterior. Enviar notas também não resolve seus comentários automaticamente.

## PR e checks

A consulta é manual e confirmada: pode usar credenciais do CLI `gh` e acessar o GitHub. Abrir o quadro, inspecionar o motor ou carregar um vínculo salvo não consulta rede. Não há criação de PR, push, merge ou correção automática de checks nesta entrega.

O sidecar valida o destino GitHub, repositório e branch e limita tempo/saída de processos. Tokens e stderr não são copiados para o armazenamento ou a interface. Os metadados salvos mostram a última consulta; a comparação do HEAD e do estado local distingue checks da revisão atual de resultados de outro commit ou de uma árvore com alterações não publicadas. Um resultado antigo não é apresentado como validação das alterações locais.

A deduplicação de falhas usa repositório, número do PR e HEAD por agente. Reexecuções de checks no mesmo HEAD não abrem uma nova ocorrência depois que a anterior foi encerrada ou dispensada; a aba PR/CI continua exibindo os resultados da última consulta manual. Não há identidade de execução de check nesta versão.

## Medição do piloto

Métricas ficam desativadas por padrão. O opt-in abre uma janela nova; desativar limpa os dados de medição, preservando inbox, comentários e vínculos necessários ao produto. Não há envio de analytics para servidor. A exportação é local e contém somente contagens e durações, sem nomes, repositórios, IDs de agentes, prompts, código, notas ou saída de terminal.

O armazenamento local conserva metadados de deduplicação, como identidades dos agentes já contabilizados e dias ativos; eles não são exportados. O mesmo arquivo contém os dados funcionais de inbox, notas e PR, que podem ser sensíveis. Há limites de armazenamento; ao atingi-los, a operação informa erro e preserva o arquivo, sem apagar histórico automaticamente.

O arquivo tem limite de 8 MiB, 4096 registros por coleção principal e 1024 comentários de até 8192 bytes cada. Durações individuais são limitadas a 30 dias; as contagens de visitas têm intervalo mínimo de 30 minutos. Esses agregados não oferecem uma distribuição individual dos tempos nem comparação automática entre participantes.

Os indicadores são definidos em [PILOT.md](PILOT.md). Tempos de intervenção começam na observação pelo aplicativo, sujeitos ao polling e a períodos offline. A medição de entrada só registra RPC bem-sucedido, sem guardar seus bytes. Ações na interface e estados dos processos não demonstram por si só qualidade, aceitação comercial ou resolução de uma aprovação.
