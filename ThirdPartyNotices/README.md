# Avisos de terceiros

O Trama preserva os avisos diretos de Octo/orkai em [Octo-MIT.txt](Octo-MIT.txt) e SwiftTerm em [SwiftTerm-MIT.txt](SwiftTerm-MIT.txt). Octo permanece fixado em `f66aa854313026870aaf57f65d26d9cbfbf32269` (0.2.19); SwiftTerm em `5d14406844143538cd8f8851d2d8a67c1fe443e5`.

[generated/inventory.json](generated/inventory.json) registra as dependências externas resolvidas por `Engine/Cargo.lock` e `Package.resolved`, incluindo dependências opcionais, de desenvolvimento, de build e de outras plataformas. O inventário reúne os arquivos LICENSE/LICENCE, COPYING, NOTICE, COPYRIGHT e AUTHORS presentes nas fontes locais, inclusive subdiretórios e `license_file` declarado pelo Cargo. Cada entrada preserva caminho original, SHA-256 do conteúdo e referência ao texto integral em `generated/texts`. Textos idênticos são armazenados uma vez. As origens são o source/revisão Git ou o URL do arquivo `.crate` e seu checksum de `Cargo.lock`; hashes dos dois lockfiles identificam a resolução usada. O inventário antigo [dependencies.json](dependencies.json) contém somente metadados Cargo e é mantido como referência histórica, não como autoridade para a cobertura atual.

A coleta atual contém **184 pacotes externos e 150 textos distintos**. Faltam textos nos arquivos publicados de `winapi-i686-pc-windows-gnu@0.4.0` e `winapi-x86_64-pc-windows-gnu@0.4.0`. São pacotes do upstream winapi, declarando `MIT/Apache-2.0`, mas não se atribui automaticamente a eles o aviso de outro pacote. Essas ausências permanecem explícitas no inventário. Os grafos Cargo filtrados para `aarch64-apple-darwin` e `x86_64-apple-darwin` excluem ambos; em cada grafo macOS há 151 dependências externas Cargo, todas com textos coletados, além dos dois pins Swift. Esse conjunto é conservador e inclui build/dev: não é uma lista extraída do linker, nem afirma que todo pacote inventariado esteja no executável.

## Reprodução local

É necessário Python 3.9+, Git, o toolchain Cargo já utilizado pelo projeto e fontes previamente resolvidas em cache. Execute os builds normais antes se faltarem fontes. A coleta não consulta rede, não atualiza dependências e não lê credenciais:

```sh
./scripts/generate-notices.py
./scripts/generate-notices.py --check --target aarch64-apple-darwin
./scripts/generate-notices.py --check --target x86_64-apple-darwin
# Retorna 1 enquanto houver qualquer texto faltante no inventário global:
./scripts/generate-notices.py --check
```

`--check` nunca escreve: verifica também divergência de qualquer texto ou lockfile. Sem `--target`, exige cobertura de todos os pacotes; com `--target`, a exigência de textos restringe-se ao grafo Cargo selecionado e aos pins Swift, mantendo a verificação integral de divergência. `--output CAMINHO` aceita diretório novo/vazio ou saída gerada reconhecida sem arquivos estranhos; recusa symlinks e não remove arquivos alheios. O checkout Swift/Git deve corresponder à revisão resolvida. Não há fallback para textos genéricos ou busca na rede.

## Limites de distribuição

Os textos são copiados das fontes em cache; os hashes permitem comparar seu conteúdo, e os checksums de arquivos Cargo identificam a origem resolvida, sem substituir uma validação independente do cache. A coleta por nomes de arquivos não encontra obrigatoriamente todos os avisos embutidos em headers, ativos ou documentação; não é auditoria jurídica nem escolha de alternativas SPDX. Preserve o conjunto inteiro no bundle. `option-ext` declara MPL-2.0; seu texto e origem estão incluídos, mas disponibilização de fonte correspondente e demais obrigações devem ser avaliadas antes de distribuição pública. Nenhuma fonte foi modificada para esta coleta. O inventário não licencia CLIs de provedores externos, que não acompanham o bundle.
