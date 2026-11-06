# Bundle local para macOS

Na raiz do repositório, execute:

```sh
./scripts/package-app.sh
# Ou uma compilação otimizada:
./scripts/package-app.sh --release
```

O script compila Swift e Rust com a configuração escolhida e cria `.build/Trama.app`. O padrão é debug. Exige macOS 14+, ferramentas Swift 6 e Rust compatível com `Engine/Cargo.toml`; usa o mesmo wrapper Rust de `build-engine.sh`. Dependências podem ser baixadas durante o build. A saída contém apenas a arquitetura compilada nesta máquina.

O bundle inclui `Trama` e `trama-engine` em `Contents/MacOS`, recursos SwiftPM (incluindo SwiftTerm) em `Contents/Resources` e a pasta completa `ThirdPartyNotices`. A revisão fixada do SwiftTerm procura seus recursos diretamente em `Bundle.main.resourceURL`, incluindo `Contents/Resources/SwiftTerm_SwiftTerm.bundle`; ela deliberadamente não usa o accessor `Bundle.module` gerado pelo SwiftPM. Nenhum link ou recurso é colocado na raiz do `.app`, preservando o layout exigido pela verificação estrita da assinatura. O sidecar é encontrado ao lado do executável principal. `TRAMA_ENGINE_PATH`, quando definido com caminho absoluto, continua sendo uma substituição explícita para desenvolvimento.

A montagem ocorre em diretório temporário; o script substitui somente o bundle gerado anteriormente após concluir a montagem e verificar a assinatura. Não instala nem abre o aplicativo e não inicia sessões ou agentes. Feche uma instância aberta antes de substituir seu bundle.

Quando `codesign` está disponível, o script aplica e verifica assinatura ad-hoc local. Isso não identifica um desenvolvedor nem fornece notarização; não é uma entrega pronta para distribuição pública. Na ausência de `codesign`, o resultado fica sem assinatura. Assinatura Developer ID, hardened runtime, avaliação de entitlements, certificados, notarização e validação Gatekeeper em outra máquina devem ser tratados antes de distribuir. Este script não busca identidades, não usa certificados e não envia artefatos à Apple.

O aplicativo aberto pelo Finder pode receber um PATH diferente do shell. Os CLIs dos provedores precisam estar instalados e acessíveis ao motor. O bundle não inclui esses CLIs nem credenciais. A validação de build não substitui o teste manual de abertura, recursos, entrada do terminal e detecção dos provedores.
