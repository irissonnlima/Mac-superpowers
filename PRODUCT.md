# Direção do produto — Mac Superpowers

**Nome provisório.** App nativo de cuidados com o Mac, começando por uma limpeza que explica o que encontrou e deixa a decisão com a pessoa.

## Princípios

1. **Confiança antes do número de gigabytes.** O produto não chama um arquivo de “lixo” apenas pelo nome. Quando a relação com um app não é certa, usa “possível sobra” ou “pasta de app para revisar”.
2. **Cada ação é legível.** Mostrar caminho, categoria, tamanho estimado, motivo, app associado quando conhecido e o que pode acontecer após a remoção.
3. **Reversível por padrão.** Itens selecionados vão para o Lixo. Não esvaziar o Lixo automaticamente.
4. **Uma única cor de destaque.** Superfícies neutras, tipografia e componentes SwiftUI nativos; botões e seleções usam a cor de destaque do sistema. Ilustrações estáticas são neutras.
5. **Local primeiro.** A análise de arquivos acontece no Mac. Qualquer telemetria ou serviço de licença futuro precisa de uma escolha clara e política de privacidade própria.

## Primeira experiência

1. A tela abre na Visão geral e inicia uma análise somente de leitura.
2. Exibe categorias e uma estimativa de espaço: caches remanescentes e possíveis sobras por identificador.
3. A pessoa entra em uma categoria, vê caminho e explicação e pode abrir o item no Finder.
4. Nenhum item começa selecionado. A escolha é feita item a item.
5. O app confirma a seleção e move cada item para o Lixo. Mostra quais operações falharam.

Não há “saúde do Mac” em porcentagem: esse número daria uma precisão que a análise atual não tem. A avaliação é a lista verificável de achados e o espaço estimado por categoria.

## Como a detecção evolui

| Tipo | Regra inicial | Leitura correta |
| --- | --- | --- |
| Cache remanescente | Nome em formato de bundle ID sem app associado | Candidato, pois serviços e extensões também usam bundle IDs |
| Possível sobra | Preferência ou pasta com bundle ID sem app associado | Candidato, não prova de abandono |
| Serviço ou helper | Plist com app associado ausente, ou caminho do executável inexistente | Revisão individual; um serviço independente pode ser legítimo |

O scanner procura apps em `/Applications`, `/System/Applications` e `~/Applications`, inclui apps em execução e consulta registros válidos do Launch Services. Examina locais conhecidos de `LaunchAgent`, `LaunchDaemon`, helpers e plugins. Preferências e dados de suporte entram na revisão quando há vínculo explícito com um app ausente; nomes genéricos sem essa evidência ficam fora. Componentes selecionados em `/Library` exigem autorização de administrador para ir ao Lixo. O protótipo usa `do shell script` com caminhos validados; a versão comercial requer um helper assinado com `SMAppService` e validação própria. Antes de uma versão comercial, também deve tratar apps em volumes externos e incluir uma lista de exclusões editável. Pastas protegidas e itens sem permissão precisam aparecer como análise parcial, nunca como “Mac totalmente verificado”.

## Prioridade de implementação

### Qualidade da limpeza

- Relacionar um conjunto de arquivos a um app instalado usando bundle ID, nome, assinatura e metadados, com explicação da evidência.
- Adicionar análise de desinstalação guiada: selecionar um app, ver somente seus arquivos associados e mover o conjunto para o Lixo.
- Memorizar exclusões e marcar arquivos em uso; evitar sugestão de remoção de dados de apps em execução.
- Guardar histórico local das operações e facilitar a localização do item no Lixo.
- Medir progresso, permitir cancelar a análise e limitar percursos custosos sem esconder que a análise ficou incompleta.
- Testar em Macs com diferentes versões do macOS, contas, permissões, volumes, apps da App Store e instaladores próprios.

### Produto completo depois da limpeza confiável

- Lupa de espaço: arquivos grandes e antigos com filtros e prévia.
- Downloads duplicados: comparação por hash, revisão de cada cópia e preservação explícita de um original.
- Itens de inicialização: inventário e ligação com Ajustes do Sistema, sem prometer acelerar o Mac por apagar caches.
- Desinstalador e observação opcional de apps enviados ao Lixo, com consentimento separado e sem processo residente por padrão.
- Monitor do sistema com CPU, memória, atividade de disco, bateria e estado térmico; histórico local e consumo acumulado por app. A definição das métricas, suas limitações e o agente opcional de coleta contínua estão em [MONITOR.md](./MONITOR.md).

## Lançamento pago

A distribuição direta com assinatura Developer ID e notarização é o caminho inicial mais compatível com a varredura ampla da Biblioteca. Na Mac App Store, o App Sandbox muda o acesso a arquivos e exigiria outro fluxo de permissões; isso precisa ser testado antes de prometer a mesma cobertura. Uma licença única com atualizações menores incluídas é uma hipótese simples para validar, sem colocar a compra antes de uma análise gratuita verificável.

O [Pearcleaner](https://github.com/alienator88/Pearcleaner) é uma referência de funcionalidades, especialmente busca de órfãos e desinstalação. Seu README informa uma licença Apache 2.0 com Commons Clause que proíbe monetizar o próprio Pearcleaner ou versões modificadas. Por isso, este produto deve manter código, marca e imagens originais; nenhuma parte do código do Pearcleaner foi incorporada neste protótipo.

Critérios para cobrar: testes em Macs reais; suporte para análise parcial e erro de permissão; recuperação clara via Lixo; acessibilidade e VoiceOver; tema claro e escuro; tradução consistente; política de privacidade; identidade visual e nome definitivos; assinatura Developer ID; hardened runtime; notarização; teste de instalação e atualização em uma máquina limpa. O protótipo atual ainda não cumpre esses critérios.
