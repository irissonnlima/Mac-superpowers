# Monitor do sistema — especificação de produto e medição

**Estado do protótipo:** coleta local de CPU, memória, I/O, bateria e estado térmico; gráficos e rankings; histórico SQLite de 30 dias; agente em segundo plano via `SMAppService` no `.app` empacotado. A coleta é de 20 segundos em condições normais, 45 segundos em baixo consumo/estado térmico alto e 90 segundos em estado crítico. A interface visível atualiza em 10 segundos. As medições de processos podem ficar incompletas por proteção do sistema ou por processos que terminem entre amostras. As seções abaixo também descrevem melhorias planejadas, como exportação CSV, resumos anuais e comparação com períodos anteriores.

## Objetivo

Responder a duas perguntas distintas: **o que está acontecendo agora?** e **quais apps consumiram recursos ao longo do tempo?** O monitor complementa Limpeza e Disco, sem chamar uso alto de CPU ou RAM de “lixo”. Toda medição é local, e cada ranking mostra a unidade e o período usados.

## Navegação e interface

- Adicionar **Monitor** à navegação, com **Ao vivo** e **Histórico**. No conteúdo, alternar CPU, Memória, Atividade do disco, Bateria e Temperatura/estado térmico. Disco ocupado continua no módulo **Disco**; atividade do disco significa bytes lidos e escritos por segundo.
- Cabeçalho fixo e compacto: título, estado da coleta, hora da última amostra e intervalo selecionado (`15 min`, `1 h`, `24 h`, `7 d`, `30 d`). Gráficos e listas rolam juntos no restante da página.
- Usar a superfície translúcida atual, a cor de destaque do sistema e poucas caixas. Nas curvas sobrepostas, diferenciar séries também por traço e rótulo, não apenas por cor. Um cartão só é necessário para resumo ou detalhe de um app.
- Cada seção apresenta um gráfico temporal, uma explicação curta da unidade e uma lista de apps ordenável por **agora**, **total no intervalo** ou **pico**. Uma linha mostra ícone/nome, valor atual, acumulado, tendência e a indicação `medido`, `estimado` ou `sem acesso`.
- Clicar num app abre seu detalhe: gráfico próprio, CPU total e por tipo de núcleo quando disponível, pico e média de memória, leitura/escrita, períodos de execução e comparação com o período anterior. Apps auxiliares são agrupados quando há vínculo verificável com o mesmo bundle; processos sem vínculo ficam em **Outros processos**, sem atribuição forçada.
- Bateria é omitida em Macs sem bateria. A tela **Térmico** mostra temperaturas em °C para cada sensor SMC/HID que o hardware permitir ler, com o código original do sensor. A leitura da bateria usa o registro local quando disponível. O estado térmico (`normal`, `elevado`, `alto`, `crítico`) permanece separado das temperaturas.

## Métricas e unidades

| Seção | Ao vivo | Histórico / ranking |
| --- | --- | --- |
| CPU | Ocupação total do Mac e núcleos equivalentes por app; até 100% por núcleo lógico | **Tempo de núcleo** (`core-s`, `core-h`), pico de núcleos equivalentes e média no período |
| Memória | Memória física total, uso do sistema, swap e pegada física por processo | Pico, média e **GB·h** por app; GB·h expressa ocupação mantida, não RAM adicional instalada |
| Disco | Leitura e escrita em MB/s; espaço disponível do volume como dado separado | GB lidos e escritos por app; uso de espaço por pasta continua no mapa de Disco |
| Bateria | Carga %, carregando/descarregando, alimentação externa e modo de pouca energia | Curva de carga, trechos de descarga, taxa `%/h` e tempo observado; não converter queda de % diretamente em consumo de cada app |
| Térmico | Temperatura por sensor em °C e estado térmico do macOS | Uma leitura por sensor a cada 5 minutos e histórico de 30 dias |

### Regra de CPU acumulada

Para um processo observado entre amostras `i` e `i+1`:

```
tempo_de_núcleo = Δ(tempo_de_CPU_do_processo)
núcleos_equivalentes = tempo_de_núcleo / Δ(tempo_de_parede)
CPU_%_do_app = 100 × núcleos_equivalentes
CPU_%_do_Mac = 100 × Σ(tempo_de_núcleo) / (Δparede × núcleos_lógicos_ativos)
```

`90%` de **um núcleo** durante 100 segundos = **90 core-s**. `230%` durante 90 segundos = **207 core-s**, ou **3,45 core-min**. Um app pode passar de 100% porque usa vários núcleos. O percentual do Mac tem outro denominador; as duas porcentagens devem ter rótulos distintos. Para evitar dupla contagem, somar apenas o tempo próprio de cada processo, não o tempo acumulado de seus filhos.

Os contadores de processo são cumulativos e devem ser convertidos da unidade de tempo informada pela API para segundos antes da subtração. Identificar a instância por **PID + início do processo** para não misturar processos quando um PID é reutilizado. Valores negativos, contadores indisponíveis e intervalos interrompidos viram lacunas, nunca zero. Um processo que nasce e termina inteiramente entre duas coletas pode escapar; a cobertura é indicada na interface.

### Núcleos de alto desempenho e de eficiência

- Ler `hw.nperflevels`, `hw.perflevelN.name` e `hw.perflevelN.logicalcpu` em tempo de execução. Não assumir que sempre existem exatamente P e E: alguns Macs têm um nível, e modelos recentes podem ter `Super` e `Performance`.
- Em Macs com dois níveis explicitamente chamados `Performance`/`Efficiency` ou `Super`/`Efficiency`, oferecer acumulados separados **quando** os contadores de processos permitirem atribuição confiável. `rusage_info_v6` expõe tempo de CPU em P-cores; o restante do tempo próprio é apresentado como tempo no nível de eficiência nesse arranjo de dois níveis. O protótipo ainda precisa de comparação lado a lado com o Monitor de Atividade em outros modelos de hardware.
- Para o total do sistema, `host_processor_info` informa carga por processador lógico; mapear cada índice a um nível somente com uma correspondência validada. A contagem de núcleos por nível, isoladamente, não prova quais índices pertencem ao nível. Se a correspondência falhar, mostrar carga total e topologia, sem inventar curvas P/E.
- Manter nomes de níveis fornecidos pelo sistema. Em gráficos, usar a cor de destaque com intensidades e traços diferentes; a legenda mostra o nome e a quantidade de núcleos.

## Fontes no macOS

- **Processos:** `proc_listpids` e `proc_pid_rusage`/`proc_pidinfo` para tempo de CPU, pegada de memória e bytes de I/O, com fallback por versão do sistema. `NSWorkspace.runningApplications` fornece identidade dos apps visíveis; resolução por bundle/executável e relação de processos auxiliares precisa guardar a evidência da associação. Alguns processos do sistema podem negar leitura.
- **CPU e memória do sistema:** estatísticas Mach (`host_statistics64`, `host_processor_info`), memória física de `ProcessInfo` e `sysctlbyname` para topologia. O total de pegadas de processos não deve ser apresentado como se fosse idêntico ao uso total de memória do Mac.
- **Armazenamento:** espaço do volume via `FileManager`/APFS; atividade por processo pelos contadores de I/O. O mapa de Disco continua responsável por ocupação por pasta.
- **Bateria:** `IOPowerSources` para capacidade atual, estado da alimentação e informações opcionais. Nem todas as chaves estão disponíveis em todos os Macs. `ProcessInfo.isLowPowerModeEnabled` registra mudança de modo de energia.
- **Térmico:** `ProcessInfo.thermalState` é uma classificação, não uma temperatura em °C. Sensores SMC e HID são descobertos no hardware e lidos no máximo uma vez por minuto; valores ausentes ou implausíveis não aparecem. Os nomes exatos e a cobertura variam por modelo. Essas interfaces de sensores não têm contrato público de estabilidade e podem não ser aceitas na Mac App Store; validar a distribuição comercial antes do lançamento. Nenhuma leitura requer senha de administrador.
- **Energia por app:** `rusage_info_v6` pode expor energia de CPU em nanojoules em sistemas compatíveis. Mostrar como **energia de CPU medida pelo kernel** somente quando houver dados válidos; ela não representa toda a energia de tela, GPU, rede e periféricos. Sem esse contador, a lista de apps durante uma descarga é apenas **atividade coincidente**, nunca “culpados pela bateria”.

## Coleta e histórico

1. Coleta ao vivo a cada **2 segundos** enquanto a janela do Monitor está aberta; reduzir atualização visual fora da seção. A coleta de bateria pode ser a cada **60 segundos**. Medir e exibir o custo do próprio Mac Superpowers.
2. Guardar amostras recentes num buffer circular para o gráfico ao vivo. Persistir agregados de **1 minuto** em SQLite local: soma de core-s, bytes lidos/escritos, média e máximo de memória, amostras válidas, cobertura e estado de energia. Guardar também segmentos da curva de bateria com carimbo de hora e estado de carga. Nunca registrar caminhos de arquivos, conteúdo de janelas ou títulos.
3. Agregar por `bundle ID + instância` quando há associação confiável; manter o detalhe de processos e consolidar por bundle para o ranking. Registrar explicitamente `sem identificação` e `sem acesso`. Não somar processos inacessíveis como zero. Retenção sugerida: **30 dias** em resolução de 1 minuto e **1 ano** em resumos de 1 hora, com limite configurável de armazenamento e botão para apagar histórico.
4. O histórico só fica contínuo com coleta em segundo plano. Oferecer uma opção separada **“Registrar histórico mesmo com o app fechado”** que registra um agente assinado com `SMAppService` após escolha do usuário. Ele deve amostrar de modo mais econômico, parar/retomar sem lacunas falsas e expor seu estado e custo na UI. Sem agente, o período em que o app esteve fechado aparece como **não monitorado**.
5. Tratar suspensão, reinício, troca de usuário, mudança do relógio, PID reutilizado, troca de volume e falta de permissão. Usar relógio monotônico para taxas e carimbo de parede para a linha do tempo. Um intervalo afetado por sleep ou por leitura incompleta recebe marca de lacuna.

## Bateria e “apps ofensores”

Mostrar **duas listas distintas** no detalhe de um período de descarga:

1. **Energia de CPU registrada**, quando `rusage_info_v6` fornecer valores válidos para os processos observados. É uma medida parcial de energia, com período e cobertura.
2. **Apps mais ativos durante esta descarga** por core-h, gravações e tempo em primeiro plano. Isso indica coincidência útil para investigação, sem atribuir a queda da bateria diretamente ao app.

O gráfico de bateria divide sessões ao conectar/desconectar a fonte, mostra inclinação `%/h` só em trechos suficientemente longos e separa carregamento, descarga e períodos sem coleta. Não classificar um app como causa da descarga com base apenas na curva de carga.

## Entregas de implementação

1. **Base confiável:** amostrador do sistema/processos, CPU core-s, memória, I/O, bateria e estado térmico; tela Ao vivo com gráfico e lista. Testes de deltas, PID reutilizado, gaps e agrupamento.
2. **Histórico local:** SQLite, agregação por minuto, filtros de período, rankings, detalhe por app, retenção e exportação CSV com unidades.
3. **Coleta contínua opcional:** agente `SMAppService`, controle claro de início/parada e comparação de custo do próprio monitor.
4. **Níveis de núcleo e energia:** validar P/E e contadores de energia em Macs Intel e gerações diferentes de Apple Silicon; degradar com clareza quando faltarem dados.

O primeiro protótipo deve ser testado lado a lado com o Monitor de Atividade em Macs reais. Divergências precisam ser explicadas pela unidade, pelo intervalo de coleta ou pela cobertura dos processos antes de virar um número comercial.

## Referências primárias

- Apple, [topologia de núcleos via `sysctlbyname`](https://developer.apple.com/documentation/kernel/1387446-sysctlbyname/determining_system_capabilities).
- Apple, [apps em execução com `NSWorkspace`](https://developer.apple.com/documentation/appkit/nsworkspace/runningapplications).
- Apple, [informações de bateria via IOPowerSources](https://developer.apple.com/documentation/iokit/1523867-iopsgetpowersourcedescription).
- Apple, [estado térmico](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property) e [modo de pouca energia](https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled).
- Apple, [registro de agentes com `SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice).
- Apple XNU, [contadores de tempo e energia de CPU](https://github.com/apple-oss-distributions/xnu/blob/main/doc/observability/recount.md).
