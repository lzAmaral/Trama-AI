# Apresentação do Trama

O [vídeo de 38 segundos](media/trama-portfolio.mp4) apresenta o projeto com capturas nativas e dados fictícios. É uma apresentação editada, não uma gravação contínua de uso nem evidência de execução autenticada de IA. O rótulo acompanha todas as cenas.

Arquivos para divulgação:

- [Vídeo MP4](media/trama-portfolio.mp4): 1080 × 1080, 60 fps, sem áudio.
- [Captura principal](media/trama-workspace.png): 2880 × 1800 pixels, renderizada em janela lógica 1440 × 900.
- [Lista](media/trama-list.png) e [compositor](media/trama-composer.png).
- [Timeline editável](media/portfolio-source/timeline.html), [origem visual e roteiro](media/portfolio-source/brand.md).

As capturas usam as views do aplicativo com projetos temporários, tarefas e provedores fictícios. O motor de fixture só permite inspeção e listagem. Nenhum holder ou CLI de IA é criado por esse script. Os diretórios de fixture são removidos após as capturas; não são usados dados do armazenamento pessoal.

O teste interativo separado conseguiu criar um shell controlado pela UI, mas a ferramenta de captura devolveu imagens reduzidas/deformadas. Por isso essas imagens não foram usadas no vídeo. O seletor de pastas, fechamento de aba e outras limitações constam em [PORTFOLIO_VALIDATION.md](PORTFOLIO_VALIDATION.md). Não confundir esse teste com as capturas do vídeo.

## Reproduzir as capturas

Na raiz do projeto, com o build de desenvolvimento disponível:

```sh
swift build --jobs 2
TRAMA_PORTFOLIO_BIN=$(swift build --show-bin-path)
mkdir -p .build/portfolio-video
swiftc -parse-as-library -swift-version 6 \
  -I "$TRAMA_PORTFOLIO_BIN/Modules" scripts/render-portfolio-preview.swift \
  -Xlinker -filelist -Xlinker "$TRAMA_PORTFOLIO_BIN/Trama.product/Objects.LinkFileList" \
  -o .build/portfolio-video/render-preview
.build/portfolio-video/render-preview docs/media
```

O diretório temporário e as durações exibidas variam entre execuções. O script não modifica preferências ou dados reais do Trama.

## Reproduzir o vídeo

Requer Python 3, FFmpeg no PATH e o Chromium gerenciado pelo Playwright. As dependências abaixo ficam no diretório de build local; o primeiro preparo baixa os pacotes e o navegador.

```sh
python3 -m venv .build/portfolio-video-venv
.build/portfolio-video-venv/bin/pip install playwright==1.65.2
export PLAYWRIGHT_BROWSERS_PATH="$PWD/.build/portfolio-browsers"
.build/portfolio-video-venv/bin/playwright install chromium --only-shell
.build/portfolio-video-venv/bin/python scripts/render-portfolio-video.py --check
.build/portfolio-video-venv/bin/python scripts/render-portfolio-video.py \
  --output .build/portfolio-video/trama-portfolio.mp4
```

O renderer não sobrescreve uma saída existente. O resultado é silencioso, sem perfis de navegador, contas ou serviços externos durante a renderização. A timeline também pode ser aberta localmente com `?t=16` para inspecionar uma cena.

## Verificação

- Três capturas nativas inspecionadas; nomes sintéticos, pasta temporária e identificação de prévia visíveis.
- Timeline conferida em sete instantes e em 380 amostras a 10 fps pelo `render.py --test` / `--sweep 10` da skill motion-designer: nenhuma sobreposição, corte ou falha JavaScript. O `--check` do renderer incluído no repositório repetiu 380 amostras para limites e erros JavaScript; esse check menor não detecta sobreposição entre pares de elementos.
- Exportação final pelo renderer do repositório: H.264, 38 s, 1080 × 1080, 60 fps, 2.280 quadros, 2.296.057 bytes e nenhum stream de áudio; conferido com `ffprobe`.
- QC dos quadros codificados: zero quadros quase pretos/brancos; folhas de contato e cortes inspecionados. A ferramenta `qc_video.py` recebeu uma cópia do stream de vídeo com uma faixa temporária de silêncio para compatibilidade; o MP4 entregue permanece sem áudio. Alertas de quadros estáticos correspondem às pausas intencionais de leitura.
- Os quadros do aplicativo são estáticos; movimento discreto de escala e títulos pertence à edição do vídeo. Esses movimentos não representam ações do usuário ou execução do agente.
- Não houve publicação no LinkedIn, upload de vídeo ou aprovação humana do material nesta etapa.
