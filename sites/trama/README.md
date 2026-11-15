# Landing page do Trama

Site estático em português, com direção visual elaborada pelo Astra e animações GSAP. A demonstração usa somente dados ilustrativos e não inicia agentes, chama APIs de IA ou acessa projetos locais.

A revisão Frontend Craft mantém essa base e reorganiza a apresentação em uma abertura verde profundo, seções claras e uma janela de demonstração escura. O fio visual relaciona sessões, execução e revisão. A rolagem desenha as conexões e monta o quadro; textos permanecem legíveis durante o movimento.

## Executar localmente

```sh
cd sites/trama
python3 -m http.server 4173 --bind 127.0.0.1 --directory dist
```

Abra `http://127.0.0.1:4173`. Não há instalação nem build de frontend. Fontes, JavaScript e ícones são servidos localmente.

## Estrutura e contratos

- `dist/index.html`: conteúdo e demonstração com abas acessíveis.
- `dist/styles.css`: layout responsivo, fontes e preferência por movimento reduzido.
- `dist/app.js`: tabs com teclado, menu móvel, ações simuladas e GSAP.
- `dist/assets`: dependências fixadas, fontes e seus avisos de licença.
- `.openai/hosting.json`: configuração local de hospedagem, fora do versionamento no repositório principal.

O código estático, os assets e as licenças do site são versionados junto ao aplicativo em `sites/trama`. O histórico do repositório local anterior foi preservado em `.build/git-backups/` durante a integração. Enviar o código ao GitHub não publica nem sincroniza a hospedagem do Site. O HTML/CSS foi atribuído ao Astra; JavaScript, assets e integração ao agente principal. Uma segunda revisão verifica comportamento, acessibilidade e afirmações antes da publicação.

## Conteúdo e referências

O público é quem desenvolve com agentes de código em projetos locais no macOS. A página convida a explorar a demonstração e acompanhar o projeto. As capacidades foram conferidas com `README.md`, `docs/ROADMAP.md` e `docs/ENGINE_INTEGRATION.md` do Trama em 14/11/2026. Abertura pública e licença MIT do aplicativo aparecem como planejadas: esta entrega não licencia nem publica o repositório principal e não oferece um download notarizado.

Situação A da skill de copywriting: briefing aberto, com fatos e voz fornecidos pela documentação do produto. Os textos priorizam tarefas observáveis (abrir uma intervenção, conferir um diff, confirmar um envio), em vez de promessas de produtividade não medidas.

Skills consultadas:

- [Frontend Craft, enzodevs](https://github.com/enzodevs/frontend-craft/blob/b22e8d0e1a2282f00a85e5c647428c005e96bd68/SKILL.md), revisão `b22e8d0e1a2282f00a85e5c647428c005e96bd68`. Aplicada por leitura do contrato, direção, escrita, movimento e acessibilidade, sem instalação global ou cópia dos seus componentes. Licença MIT original e avisos de terceiros revisados.
- [GSAP oficial](https://github.com/greensock/gsap-skills), em especial core, timeline e ScrollTrigger; cópias já disponíveis no ambiente.
- [Copywriting, Corey Haines](https://github.com/coreyhaines31/marketingskills/blob/main/skills/copywriting/SKILL.md), encontrada no [catálogo skills.sh](https://skills.sh/coreyhaines31/marketingskills/copywriting), com verificação do checklist de linguagem. Aplicada por leitura, sem instalação global.
- Sites: implementação estática, revisão e publicação privada.

Não foram copiados templates ou código de referências de produto.

## Licenças de terceiros

- GSAP e ScrollTrigger **3.15.1**, obtidos do pacote oficial via jsDelivr: [GSAP Standard License](https://gsap.com/standard-license/). Texto preservado em `dist/assets/GSAP-LICENSE.txt`; cabeçalhos originais mantidos. GSAP não está coberto pela licença MIT do código próprio desta landing page.
- Instrument Sans, variável: [google/fonts/ofl/instrumentsans](https://github.com/google/fonts/tree/main/ofl/instrumentsans), SIL Open Font License, texto e créditos em `dist/assets/instrumentsans-OFL.txt`.
- IBM Plex Mono Regular: [google/fonts/ofl/ibmplexmono](https://github.com/google/fonts/tree/main/ofl/ibmplexmono), SIL Open Font License, texto e créditos em `dist/assets/ibmplexmono-OFL.txt`.

O código original desta landing page é disponibilizado sob MIT, no arquivo `LICENSE`. As dependências preservam suas próprias licenças. Isso não altera o licenciamento do aplicativo Trama ou de seu motor.
