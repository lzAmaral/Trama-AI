# Bundle local para macOS

Na raiz do repositório, execute:

```sh
./scripts/package-app.sh
# Ou uma compilação otimizada:
./scripts/package-app.sh --release
# Preservar um bundle já aberto durante a validação:
./scripts/package-app.sh --output .build/validation/Trama.app
```

O script compila Swift e Rust com a configuração escolhida e cria `.build/Trama.app`. O padrão é debug. `--output` permite outro diretório `.app` dentro de `.build`, fora de outros bundles; destinos inválidos são recusados antes de compilar. Exige macOS 14+, Python 3, ferramentas Swift 6 e Rust compatível com `Engine/Cargo.toml`; usa o mesmo wrapper Rust de `build-engine.sh`. Dependências podem ser baixadas durante o build. A saída contém apenas a arquitetura compilada nesta máquina.

O bundle inclui `Trama` e `trama-engine` em `Contents/MacOS`, recursos SwiftPM (incluindo SwiftTerm) em `Contents/Resources` e a pasta completa `ThirdPartyNotices`. A revisão fixada do SwiftTerm procura seus recursos diretamente em `Bundle.main.resourceURL`, incluindo `Contents/Resources/SwiftTerm_SwiftTerm.bundle`; ela deliberadamente não usa o accessor `Bundle.module` gerado pelo SwiftPM. Nenhum link ou recurso é colocado na raiz do `.app`, preservando o layout exigido pela verificação estrita da assinatura. O sidecar é encontrado ao lado do executável principal. `TRAMA_ENGINE_PATH`, quando definido com caminho absoluto, continua sendo uma substituição explícita para desenvolvimento.

A montagem ocorre em diretório temporário; o script substitui somente o bundle gerado anteriormente após concluir a montagem e verificar a assinatura. A publicação preserva o bundle anterior em backup fora do staging e o restaura se a troca falhar. Se também falhar a restauração, informa o caminho recuperável e não apaga o backup. Não há garantia de atomicidade contra perda de energia entre os dois renames. Não instala nem abre o aplicativo e não inicia sessões ou agentes. Feche uma instância aberta antes de substituir seu bundle, ou use `--output` separado.

Quando `codesign` está disponível, o script aplica e verifica assinatura ad-hoc local. Isso não identifica um desenvolvedor nem fornece notarização; não é uma entrega pronta para distribuição pública. Na ausência de `codesign`, o resultado fica sem assinatura. Este script não busca identidades, não usa certificados e não envia artefatos à Apple.

`scripts/distribute-app.sh` prepara uma cópia separada em `.build/distribution` somente com `--identity` Developer ID explícita. O opt-in adicional `--notarize --keychain-profile` envia um ZIP à Apple usando um perfil existente; sem esses argumentos não há notarização. O script exige resposta `Accepted`, valida o ticket e recria o ZIP após o staple. Ele não cria perfis nem busca certificados. O fluxo real depende de identidade/configuração externas e não foi validado com certificados nesta entrega; testes usam ferramentas falsas. Entitlements, compatibilidade com hardened runtime e abertura/Gatekeeper em outra máquina continuam obrigatórios antes de distribuir. Consulte `scripts/distribute-app.sh --help` e [evidências das ferramentas](../scripts/VALIDATION.md).

Antes da distribuição, confira os [avisos transitivos](../ThirdPartyNotices/README.md). O gerador usa fontes locais fixadas e verifica separadamente a cobertura de cada target macOS. A política para um futuro canal de atualizações autenticado e os critérios externos ficam em [RELEASE_VALIDATION.md](RELEASE_VALIDATION.md); o aplicativo não instala atualizações automaticamente.

O aplicativo aberto pelo Finder pode receber um PATH diferente do shell. Os CLIs dos provedores precisam estar instalados e acessíveis ao motor. O bundle não inclui esses CLIs nem credenciais. A validação de build não substitui o teste manual de abertura, recursos, entrada do terminal e detecção dos provedores.
