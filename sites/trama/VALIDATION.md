# Validação da landing page

## Frontend Craft — 15/11/2026 (prévia local)

Contrato: refazer a apresentação no mesmo site estático, mantendo identidade, demonstração, conteúdo verificável e GSAP. Astra responsável por HTML/CSS; integrador por JavaScript, documentação e integração; agente independente responsável pela revisão. Nenhuma alteração no aplicativo nativo, motor, hospedagem ou audiência.

Skill consultada: `enzodevs/frontend-craft`, revisão `b22e8d0e1a2282f00a85e5c647428c005e96bd68`. A direção relaciona fios de conexão e janelas de trabalho do macOS. Superfície verde profundo na abertura, fundo claro frio para leitura e demonstração escura. A numeração indica somente etapas. Animação focal nos fios e montagem do quadro, sem reduzir a opacidade do texto durante a rolagem.

- Revisão independente do JavaScript em VM passou para abas, setas/Home/End, envio vazio e preenchido, recuperação do erro, ações ilustrativas, menu e Escape. Com e sem biblioteca de animação, o envio mantém a aba escolhida.
- Condições desktop/mobile, foco e cleanup foram exercitadas com mocks. A ativação de movimento reduzido interrompe e limpa a transição de abas. O foco já presente no quadro durante resize é considerado na configuração de movimento.
- `swift build` passou. `swift test` executou 154 testes e reportou a mesma falha nativa já observada na entrega anterior: `closingTheDetailDuringInputPreservesItsConfirmedDelivery`, esperando o arquivo temporário `entered`. A suíte nativa completa não está verde; esta revisão não alterou arquivos Swift/Rust.

- Versão final: `node --check dist/app.js`, `git diff --check`, referências HTML/ARIA/assets e HTTP local 200 passaram. Revisão independente sem achados pendentes. Contraste calculado para os pares críticos: texto secundário 5,10:1, texto do hero 8,82:1, CTA 10,80:1 e foco claro 5,04:1.
- Base CSS mobile-first, com controles de pelo menos 44px e rolagem interna no quadro. A análise estática de 320px não identificou overflow evidente. Removida a margem negativa do diagrama no tablet; deslocamento horizontal do fluxo limitado a 24px, menor que a margem disponível no desktop.
- A prévia local foi aberta em janela própria do Chrome. A captura falhou com `SCStreamErrorDomain -3811`; o host de acesso isolado ao navegador estava indisponível e a tentativa de abrir Safari retornou timeout. Portanto o redesign não tem verificação visual completa, teste real de 320px ou reprodução observada dos efeitos. Mocks não validam renderização, geometria ou o runtime real do ScrollTrigger.
- Servidor preservado em `http://127.0.0.1:4173` para análise do usuário. Sem publicação ou sincronização desta revisão com o site hospedado.

## Rolagem — 15/11/2026 (prévia local)

- GSAP ScrollTrigger agora controla fios SVG, montagem do quadro, benefícios, trilha de etapas e CTA com `scrub`, permitindo avançar e voltar pela rolagem. O título do fluxo acompanha as etapas com CSS sticky no desktop.
- Montagem usa um contêiner estável como trigger. Foco dentro da demonstração suspende a montagem e revela os controles; ao sair, o vínculo com a rolagem é reativado. As abas continuam sob controle do visitante.
- `matchMedia` remove animações e listeners ao mudar de condição; movimento reduzido mantém o documento estático. Mobile usa movimentos menores e entradas verticais no fluxo e manifesto.
- Sintaxe JavaScript, `git diff --check`, referências HTML/ARIA/assets e HTTP local (200) passaram. Revisão independente verificou desktop/mobile, movimento reduzido, foco e cleanup em execução controlada com mocks; nenhum achado pendente após correções.
- A página atualizada abriu no Chrome. A inspeção visual da rolagem não foi concluída: o navegador estava em uso simultâneo e o controle nativo bloqueou novas ações após alteração pelo usuário. Não considerar os mocks uma verificação visual do movimento real.
- `swift build` passou. A suíte nativa executou 154 testes e reportou uma falha em `closingTheDetailDuringInputPreservesItsConfirmedDelivery`, esperando o arquivo temporário `entered`. A repetição isolada desse teste passou; a execução completa permanece registrada como falha. Nenhum código Swift ou Rust foi alterado nesta entrega.
- Alterações mantidas somente na prévia local em `http://127.0.0.1:4173`; sem nova publicação.

Entrega de 14/11/2026. Escopo: somente o repositório próprio em `sites/trama`; nenhuma alteração no aplicativo ou motor foi integrada por esta tarefa.

## Evidências

- `node --check dist/app.js`: passou, inclusive após a correção da simulação de envio.
- HTML: 20 IDs únicos, três tabs/panels com referências ARIA consistentes, seis FAQs e recursos/âncoras locais válidos. Revisão independente conferiu os contratos.
- Revisão independente em VM sem GSAP: tabs, setas/Home, instrução vazia/preenchida, feedback de revisão, menu e Escape passaram.
- Chrome nativo, controlado via CUA: renderização desktop do hero e quadro; intervenção abre Terminal; seta direita seleciona Revisão; prévia de revisão gera feedback; instrução vazia recebe mensagem e foco; instrução preenchida gera feedback de simulação.
- Emulação iPhone SE de 375 × 667 no Chrome: hero, menu e navegação, aba Revisão e FAQ inspecionados. Após correção, o envio simulado mantém a aba Revisão selecionada e mostra feedback; não exibe o terminal de outro agente.
- HTTP local retornou 200. JavaScript e fontes do site foram carregados do próprio servidor.
- GSAP 3.15.1 e ScrollTrigger fixados localmente; textos originais das licenças e avisos preservados. `prefers-reduced-motion` desativa animações; conteúdo básico permanece visível se a biblioteca falhar.
- No checkout do aplicativo: `swift build` passou e `swift test` passou com 154 testes. Testes condicionados ao binário do motor foram ignorados sem `TRAMA_TEST_ENGINE_PATH`; esta tarefa não alterou o motor Rust.

## Revisão e correção

O Astra foi autor do HTML/CSS. Outro agente revisou comportamento, erros, contratos e veracidade contra a documentação do Trama. O achado de coerência na ação `send` foi corrigido pelo integrador e verificado no navegador: o compositor mostra Codex, enquanto o terminal ilustrativo detalha Claude Code aguardando aprovação, portanto um novo envio simulado agora mantém a aba atual.

## Limites

Não houve teste em iPhone físico, Safari, VoiceOver ou medição de desempenho. A preferência de movimento reduzido foi revisada em código, sem alternância do ajuste do sistema. O controle de abas do navegador estava indisponível; a inspeção foi realizada pela interface nativa do Chrome. O DevTools exibia erros/avisos de extensões instaladas, que também injetavam recursos; não representam dependências do site. As verificações não executaram tarefas pagas, consultas de consumo ou provedores autenticados.

O aplicativo está em desenvolvimento. A página distingue demonstração ilustrativa, disponibilidade pública ainda pendente e MIT planejada para o Trama. O código original desta landing tem licença MIT própria, com terceiros sob suas respectivas licenças.
