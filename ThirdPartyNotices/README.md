# Dependências do motor

O executável auxiliar utiliza a biblioteca `orkai` de https://github.com/lucasmarujo/octo, revisão `f66aa854313026870aaf57f65d26d9cbfbf32269` (0.2.19).

O aviso original MIT está preservado em [Octo-MIT.txt](Octo-MIT.txt). Deve acompanhar as cópias e distribuições que incluam esse código.

[dependencies.json](dependencies.json) registra nome, versão, licença declarada e repositório das dependências resolvidas pelo Cargo, incluindo plataformas opcionais. É um inventário de metadados, não uma auditoria completa nem substituto dos textos de licença. Antes de distribuir binários, reunir os avisos exigidos pelas dependências efetivamente incluídas.

O terminal nativo usa SwiftTerm 1.20.0, revisão `5d14406844143538cd8f8851d2d8a67c1fe443e5`, com aviso em [SwiftTerm-MIT.txt](SwiftTerm-MIT.txt). As dependências Swift resolvidas ficam em `Package.resolved`; swift-argument-parser é dependência transitiva de ferramentas/plugins. O script de bundle copia este diretório junto dos recursos. O inventário Cargo inclui metadados de dependências de desenvolvimento/opcionais, não apenas código presente no binário.
