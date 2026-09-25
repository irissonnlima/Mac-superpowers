# Mac Superpowers

Protótipo nativo para macOS, escrito em Swift e SwiftUI. A primeira área é **Limpeza**.

## O que já funciona

- Analisa `~/Library/Caches`, `Application Support`, `Containers`, `HTTPStorages` e `WebKit`.
- Examina `LaunchAgents` e `LaunchDaemons` em `/Library` e `~/Library/LaunchAgents`. Quando o arquivo declara `AssociatedBundleIdentifiers`, relaciona o serviço, seu executável e plugins do mesmo fornecedor a um app ausente. Também sinaliza serviços cujo executável não existe, mesmo sem essa chave, sem afirmar que pertencem a um app removido. A partir de um vínculo explícito, procura dados com o mesmo nome ou identificador em pastas de suporte, preferências, logs e estado salvo. Esses itens aparecem em **Serviços e componentes** para revisão individual.
- A **Visão geral** reúne os achados. **Caches** mostra apenas pastas em `~/Library/Caches`; **Dados de apps** mostra pastas de `Application Support`, `Containers`, `HTTPStorages` e `WebKit`; **Serviços e componentes** mostra itens de inicialização e dados relacionados. Cada seção tem contagem e tamanho próprios, e cada item identifica sua origem.
- Mostra tamanho estimado, caminho e motivo de cada item.
- Identifica possíveis sobras por identificador de pacote, comparando com apps encontrados em `/Applications`, `/System/Applications` e `~/Applications`, apps em execução e registros válidos no Launch Services. Se outro app do mesmo fornecedor estiver instalado, evita classificar a pasta como sobra.
- Ignora nomes genéricos de pastas de suporte, caches de apps instalados, preferências pequenas, serviços compartilhados e identificadores do sistema. Eles exigem uma análise separada para serem tratados com segurança.
- Deixa a seleção vazia por padrão e exige escolha item a item.
- Move somente os itens selecionados para o Lixo, com confirmação e resultado por operação. Para componentes protegidos em `/Library`, o macOS pede autorização de administrador e o app os guarda em uma pasta identificada dentro do Lixo do usuário. Acesso Total ao Disco não concede essa permissão de escrita. Caminhos fora das áreas examinadas e links simbólicos são rejeitados antes da movimentação. Serviços ainda ativos podem exigir reinício para desaparecer dos ajustes do macOS.
- Inclui ícone e ilustrações originais, neutras, gerados na tarefa de imagens separada.
- Mostra a logo com um anel animado durante a análise inicial e nas reanálises; a tela dura no mínimo dois segundos e o resultado anterior desaparece ao iniciar uma nova análise.
- Oferece seleção de todos os itens visíveis e um resumo numerado da seleção. No macOS 26 ou superior, os botões de ação usam Liquid Glass; em versões anteriores, usam os controles nativos equivalentes.
- Inclui a seção **Disco**: começa a análise em `/`, mostra capacidade, uso e espaço disponível sem cartão no cabeçalho e cria um mapa radial de cinco níveis. Pastas da raiz têm cores distintas; subpastas mantêm a família de cor, arquivos aparecem em cinza. É possível navegar pelas pastas no mapa, voltar pelo centro, revelar arquivos no Finder e cancelar a análise.
- Salva o último mapa de `/` compactado em `~/Library/Caches/MacSuperpowers/DiskReport.json.lzfse`. Ao abrir Disco, exibe esse cache enquanto atualiza a análise em segundo plano. Arquivos menores que 8 MB são contabilizados na pasta e agrupados visualmente para limitar o tamanho do cache.
- Inclui **Monitor** com gráficos de CPU, memória, leitura/gravação de disco, bateria (quando existe) e estado térmico. A lista mostra apps e processos observados agora ou no período escolhido. O histórico registra tempo de núcleo, memória média e de pico, bytes de disco e energia de CPU quando o macOS a fornece. Em Macs que oferecem contadores compatíveis, separa o tempo observado em núcleos de desempenho e eficiência.
- O agente `MacSuperpowersMonitorAgent` coleta em segundo plano mesmo com a janela fechada. Ele mede a cada 20 segundos, reduzindo para 45 segundos no modo de pouca energia ou com estado térmico alto, e 90 segundos em estado crítico. A interface amostra a cada 10 segundos quando o Monitor está visível, em uma tarefa de baixa prioridade. As medições e agregados por minuto ficam somente em `~/Library/Application Support/MacSuperpowers/Monitor.sqlite`, com retenção de 30 dias e botão para apagar o histórico. O controle no cabeçalho liga ou desliga o agente.

**Possível sobra é um sinal para revisão, não uma prova de que o arquivo é dispensável.** Pastas podem pertencer a serviços, extensões ou apps instalados fora dos locais examinados. A estimativa de espaço também pode diferir do espaço recuperado. Nenhuma limpeza automática é executada.

A análise ainda não cobre todos os mecanismos de inicialização do macOS, como registros internos de Itens de Início sem arquivo acessível, extensões instaladas dentro de outros apps ou diretórios arbitrários. Falhas de leitura dos diretórios examinados são exibidas no relatório; zero resultados não significa cobertura total do Mac.

## Rodar

Requer macOS 14 ou superior e Xcode. Abra `Package.swift` no Xcode e execute o produto `MacSuperpowers`, ou use:

```bash
swift run MacSuperpowers
```

Para gerar um `.app` de teste local:

```bash
bash scripts/build-app.sh
open "dist/Mac Superpowers.app"
```

O script usa um identificador de pacote provisório e assinatura local por padrão. Assinaturas locais *ad hoc* podem fazer o macOS pedir permissões novamente após cada recompilação. Com um certificado instalado, defina `MAC_SUPERPOWERS_SIGNING_IDENTITY` para usar a mesma identidade nos builds de desenvolvimento. Antes de vender, defina nome e bundle ID definitivos, substitua o ícone, assine com **Developer ID**, ative o hardened runtime, notarie e teste a instalação em outra conta/Mac.

O Monitor confere a última amostra gravada pelo agente. Se o serviço estiver registrado mas parar após uma recompilação local *ad hoc*, o cabeçalho mostra que não há amostra recente e a janela volta a coletar enquanto estiver aberta. Nesse caso, desligue e religue **Coletar em segundo plano** para atualizar o registro do build local.

O fluxo administrativo atual usa o comando do sistema `mv` por meio de `do shell script ... with administrator privileges`, restrito aos caminhos revisados em `/Library`. Ele é adequado para validar o protótipo local, mas a distribuição comercial deve substituir esse mecanismo por um helper assinado e registrado com `SMAppService`, com validação do cliente e dos caminhos no próprio helper.

## Direção do produto

O primeiro lançamento deve tornar a limpeza confiável: explicar cada achado, mostrar o caminho real, permitir excluir itens da análise e oferecer histórico de movimentações ao Lixo. Depois, faz sentido adicionar desinstalação guiada de apps e downloads grandes/duplicados. Cada módulo precisa de regras e testes próprios.

As definições de medição e os limites do **Monitor do sistema** estão em [MONITOR.md](./MONITOR.md). O monitor já funciona no protótipo; exportação, resumos anuais e medição direta de temperatura em °C ainda não foram implementados.

Na seção Disco, o mapa soma os tamanhos alocados dos arquivos acessíveis em `/`. A primeira análise é salva em cache; nas próximas aberturas o mapa salvo aparece sem uma nova varredura, que só ocorre ao clicar em **Analisar novamente**. O scanner inclui os caminhos de dados ligados ao volume de inicialização por *firmlinks* e evita contar novamente `/System/Volumes/Data` e volumes externos. Fototecas protegidas também ficam fora do mapa para não pedir acesso às Fotos durante uma análise de espaço. O total mapeado não equivale necessariamente ao espaço usado do volume: snapshots APFS, clones, fototecas excluídas, arquivos compartilhados e permissões podem produzir diferenças. O app informa quando áreas não puderam ser lidas; o Acesso Total ao Disco é concedido pelo usuário nos Ajustes do Sistema.

A interface usa controles nativos, fundos neutros e a cor de destaque escolhida no macOS. As imagens devem ser originais e discretas; a tela de revisão continua útil mesmo sem ilustrações.

A janela usa uma única superfície translúcida do macOS, sem divisória entre navegação e conteúdo. Apenas o resumo, a lista de resultados e as ações selecionadas recebem painéis discretos.

## Distribuição

Para varrer amplamente a Biblioteca do usuário, a primeira via comercial mais simples é distribuição direta, fora da Mac App Store. A versão da loja exigiria App Sandbox e um fluxo de permissões/acesso a arquivos diferente. Ainda podem existir pastas protegidas que a aplicação não consegue ler ou mover, mesmo fora da sandbox. O app deve informar essas falhas com clareza.
