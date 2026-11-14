# Responsividade da interface

Rodada local de 2026-11-14, branch `fix/responsive-workspace`, sobre o redesenho Octo ainda sem commit. Mantém a direção visual aprovada pelo usuário. Nenhum arquivo Rust, pin ou contrato RPC foi alterado.

## Correções

- Cabeçalho e ações se reorganizam em linhas; títulos, projetos, sessões e branches longos têm truncamento e tooltip. Cartões reservam espaço para ID, provedor e tempo.
- Seletor de pasta do compositor usa botão flexível e popover nativo com nome e caminho explícitos. As ações passam para outra linha quando necessário.
- Editores de tarefa e instrução usam `NSTextView` sem trilhas permanentes de scrollbar. Mantêm seleção, texto literal, composição IME e undo/redo local; trocar ou limpar um rascunho não apaga o histórico de outro editor.
- Skills aparecem acima do compositor. Mensagens de erro têm área rolável limitada.
- Detalhe adapta cabeçalho, metadados e seletor de painéis; o inspetor aparece com largura disponível de pelo menos 900 pt. O terminal preserva sua identidade ao redimensionar. A área de instrução mantém o botão de envio visível nos cenários conferidos.
- Sidebar limita sua largura para preservar pelo menos 520 pt de conteúdo; tiles estreitos da grade dividem o cabeçalho em duas linhas.

## Matriz reproduzível

```sh
./scripts/render-workspace-preview.sh --responsive
```

O harness usa as views reais, stores isolados e RPC fictício; não lê o armazenamento do usuário, credenciais ou rede, nem inicia IA. Os dados incluem nomes/caminhos/branches longos, oito agentes, estados distintos, rascunho multilinha com Unicode e 12 skills fictícias. A resposta de skills é decodificada pelo cliente real e sua quantidade é verificada.

| Cenário | Tamanhos em pontos | Capturas |
| --- | --- | --- |
| Quadro, Lista, Grade e detalhe de agente | 820×560, 1024×640, 1280×800, 1440×900, 1920×1080 | 20 |
| Erros simultâneos e paleta de skills | 820×560 | 2 |
| Sidebar preferida em 380 pt, quadro e detalhe | 820×560 e 1024×640 | 4 |
| Demonstração | 820×560 e 1440×900 | 2 |

Resultado: 28 PNGs em `.build/octo-native-previews/responsive-*.png`. As 26 capturas do modo real verificam automaticamente presença e limites do editor nativo dentro do canvas, altura mínima de 40 pt e ausência de scrollers permanentes. O JSON correspondente fica em `responsive-layouts.json`. Os botões SwiftUI não expuseram frames de acessibilidade nesse modo offscreen (`controls: []`); sua visibilidade foi conferida nas imagens, sem anunciar cobertura automática desses limites.

O integrador inspecionou as capturas; um agente sem autoria revisou código e os casos estreitos. Os achados sobre seletor de pasta, envio parcialmente cortado, paleta sobre o editor e formato da fixture foram corrigidos e reverificados. Iniciar e Enviar aparecem inteiros nas capturas de 820×560 com a sidebar larga.

Na integração para `main`, a revisão identificou que filtrar outro projeto ainda trocava a pasta da próxima tarefa. O acoplamento foi removido. O harness também muda o filtro com a view montada e edita pelo `NSTextView`, verificando que o destino original recebe a edição e o rascunho do projeto filtrado permanece intacto. Essa verificação e a matriz passaram novamente no worktree isolado, assim como build e suíte Swift (141 testes reportados, 12,128 s). A suíte Cargo foi repetida antes da integração: 35 testes aprovados com processos controlados.

## Checks e limites

- `swift build`: passou pela execução do harness e pelo empacotamento.
- `swift test`: runner reportou 141 testes aprovados em 15,954 s, incluindo quatro novos testes AppKit de edição, seleção, undo/redo entre editores e composição IME. Os três testes de integração opt-in com motor compilado foram ignorados, como na rodada anterior.
- `git diff --check`: passou.
- `scripts/package-app.sh`: bundle local atualizado e assinatura ad hoc verificada.
- Cargo test não foi repetido, pois o motor não foi alterado; o empacotamento recompila Rust com `--locked`.

O controle do computador estava indisponível (`Sky Computer Use native pipe startup failed`); esta rodada valida layout offscreen e comportamento do editor via AppKit, sem comprovar interação por mouse/teclado, popovers abertos, VoiceOver ou redimensionamento contínuo do bundle. O desenho do SwiftTerm variou entre as capturas; não valida PTY real nem desempenho. Em 820×560 com erros simultâneos, o quadro fica reduzido aos cabeçalhos enquanto as ações de recuperação e composição permanecem visíveis; ampliar a janela recupera a área dos cartões. A revisão interativa e de acessibilidade continua aberta.
