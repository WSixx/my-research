# Estratégias e Exemplos: Mitigando Anomalias em Timers do Datadog

Este documento detalha cenários técnicos que geram métricas irreais (minutos ou horas) em timers e apresenta soluções práticas, utilizando Kotlin como referência para implementações nativas.

---

## 1. O Problema do Background (Suspensão pelo Sistema Operacional)

Quando o sistema operacional suspende o processo da aplicação (Doze Mode, App em Background), o relógio físico continua correndo, mas a CPU para de processar o seu código.

### 🔴 O Cenário do Problema
O usuário inicia um fluxo de processamento de imagem ou sincronização de banco de dados e minimiza o aplicativo logo em seguida.
```kotlin
fun processarDados() {
    val timer = Datadog.startTimer("processamento_dados")
    
    // Se o SO suspender o app aqui por 2 horas...
    repositorio.sincronizar() 
    
    // ...quando voltar, o Datadog vai registrar 2 horas de processamento.
    timer.stop() 
}
```

### 🟢 Medidas para Evitar
**Adicionar contexto de Lifecycle (Tags).**
Ao invés de tentar impedir o timer de rodar, adicione tags que informem o estado do aplicativo no momento em que o timer foi fechado. Isso permite que você filtre essas anomalias nos Dashboards usando `app_state:foreground`.

```kotlin
fun processarDados(isAppInForeground: Boolean) {
    val timer = Datadog.startTimer("processamento_dados")
    
    try {
        repositorio.sincronizar()
    } finally {
        // Envia o timer com a tag do estado atual
        val tag = if (isAppInForeground) "app_state:foreground" else "app_state:background"
        timer.stop(tags = listOf(tag))
    }
}
```

---

## 2. Vazamento de Timers (Falta de `finally`)

Exceções não tratadas podem interromper o fluxo de execução antes que a linha `stop()` seja atingida. O timer fica em memória até ser eventualmente fechado ou sobrescrito por um mecanismo de fallback, gerando tempos bizarros.

### 🔴 O Cenário do Problema
```kotlin
fun buscarDetalhes() {
    val timer = Datadog.startTimer("api_request_detalhes")
    
    val resposta = api.getDetalhes()
    if (!resposta.isSuccessful) {
        throw IllegalStateException("Erro na API") // O timer nunca é parado aqui!
    }
    
    timer.stop()
}
```

### 🟢 Medidas para Evitar
**Encapsular a medição em funções de High-Order (Try/Finally inline).**
Crie uma extensão para garantir que o timer sempre será parado, independentemente do que aconteça dentro do bloco.

```kotlin
inline fun <T> measureDatadogTimer(metricName: String, tags: List<String> = emptyList(), block: () -> T): T {
    val timer = Datadog.startTimer(metricName)
    return try {
        block()
    } finally {
        timer.stop(tags)
    }
}

// Uso seguro:
fun buscarDetalhesSeguro() {
    measureDatadogTimer("api_request_detalhes") {
        val resposta = api.getDetalhes()
        if (!resposta.isSuccessful) throw IllegalStateException("Erro")
    } // O timer para no "finally" interno da função, mesmo com a exception.
}
```

---

## 3. Coroutines e Espera Infinita (Starvation / Suspensão Longa)

Em arquiteturas assíncronas, uma coroutine pode ficar suspensa indefinidamente aguardando uma thread ser liberada no `Dispatchers.IO` ou aguardando um recurso que travou.

### 🔴 O Cenário do Problema
```kotlin
suspend fun calcularHashComplexo() = withContext(Dispatchers.Default) {
    val timer = Datadog.startTimer("calculo_hash")
    
    // Se a thread pool estiver esgotada, a suspensão abaixo pode demorar minutos
    // antes mesmo do processamento real começar.
    val hash = criptografia.gerarHash(arquivo) 
    
    timer.stop()
}
```

### 🟢 Medidas para Evitar
**Utilizar `withTimeout` do pacote Coroutines.**
Force a interrupção da execução (lançando uma `TimeoutCancellationException`) se o tempo exceder o limite aceitável do negócio. Isso impede que o timer chegue a horas de duração.

```kotlin
suspend fun calcularHashComplexoSeguro() = withContext(Dispatchers.Default) {
    measureDatadogTimer("calculo_hash") {
        // Se passar de 5 segundos, a coroutine é cancelada, cai no finally 
        // da nossa função inline e o Datadog registra no máximo ~5s.
        withTimeout(5000L) {
            criptografia.gerarHash(arquivo)
        }
    }
}
```

---

## 4. Transições de Rede e Sockets Zumbis (OkHttp)

Quando a conexão cai no meio de um request (ex: saindo do Wi-Fi para o 4G), o socket TCP pode não ser encerrado imediatamente pelo Kernel. A biblioteca de rede pode ficar aguardando o timeout padrão (que pode ser de minutos no nível do SO).

### 🔴 O Cenário do Problema
Você usa um interceptor do Datadog para medir as chamadas de rede, mas a configuração do Client HTTP permite tempos infinitos de leitura.
```kotlin
// Cliente sem timeouts configurados adequadamente
val client = OkHttpClient.Builder()
    .addInterceptor(DatadogInterceptor())
    .build() 
```

### 🟢 Medidas para Evitar
**Configuração estrita de Timeouts no Client HTTP.**
Garanta que seu cliente tenha um ciclo de vida de request muito bem delimitado. Isso "corta" pela raiz os picos de vários minutos nas métricas de rede no Datadog.

```kotlin
val client = OkHttpClient.Builder()
    .connectTimeout(15, TimeUnit.SECONDS) // Tempo máximo para abrir a conexão com o servidor
    .readTimeout(20, TimeUnit.SECONDS)    // Tempo máximo sem receber nenhum pacote de dados
    .writeTimeout(20, TimeUnit.SECONDS)   // Tempo máximo aguardando para enviar dados
    .addInterceptor(DatadogInterceptor())
    .build()
```
*Com essa configuração, é fisicamente impossível que um timer de rede do interceptor passe de algumas dezenas de segundos. Qualquer anomalia maior do que isso será barrada pelo Timeout do OkHttp.*

---

2.1 O Papel Crítico das Funções de Alta Ordem e do Modificador inline
A linguagem Kotlin providencia mecanismos de encapsulamento extremamente sofisticados, nomeadamente funções de alta ordem (Higher-Order Functions). Uma função de alta ordem é uma função que recebe outra função (um bloco lambda) como parâmetro. Contudo, em código de instrumentação extensiva — que poderá ser invocado centenas de vezes por segundo durante as renderizações do Jetpack Compose, por exemplo — a passagem de lambdas resulta na instanciação contínua de objetos anónimos do tipo Function no heap da Máquina Virtual (ART/Dalvik), induzindo Garbage Collection agressivo e deteriorando a performance, ou seja, gerando o chamado Efeito do Observador (onde o monitoramento prejudica o sistema monitorizado).

O uso do modificador inline nestes wrappers de instrumentação é, por conseguinte, obrigatório. O modificador inline instrui o compilador Kotlin a evitar a alocação de memória na pilha. Em vez de instanciar a closure, o compilador extrai o código da função e injeta-o diretamente no local de chamada, garantindo uma penalidade de performance absolutamente nula.

Para assegurar que o encerramento do temporizador ocorra infalivelmente, a construção idiomática central e inegociável é o bloco sintático try/finally. A cláusula finally possui garantia de execução garantida na JVM e no Android Runtime (ART) ao sair do escopo semântico do bloco try, quer a saída tenha ocorrido por uma conclusão natural, por um retorno precoce, ou pela emissão de uma exceção catastrófica.

5.1 O Privilégio Estatístico dos Percentis (P95 e P99)A literatura analítica e o modelo SRE da Google sublinham o uso compulsivo de metodologias baseadas em Percentis.O p50 (Mediana): Descreve fielmente a latência pura vivida por metade da base total de utilizadores num determinado período de processamento diário. Descreve o "utilizador normal".O p95 (Percentil 95): Refere que 95% dos utilizadores experienciam um atraso abaixo deste limiar. Neutraliza matematicamente os 5% que contêm o ruído anómalo residual e os estrangulamentos insuperáveis.O p99: Fornece um espetro severo, demonstrando a experiência da camada superior afetada, sem permitir que o dispositivo em estado catastrófico absoluto distorça a métrica.

## Resumo das Melhores Práticas para Dashboards

1. **Nunca alerte no `Max`**: Alertas baseados em valores máximos sofrerão de "fadiga de alerta" devido a falsos positivos.
2. **Foque no `p95` e `p99`**: Use a query `p95:sua_metrica.tempo` para os gráficos principais. Isso limpa automaticamente o topo do gráfico.
3. **Use Facets / Tags**: Ao investigar no Datadog, agrupe as queries por versão do app ou por estado (background/foreground) para isolar de onde a anomalia está vindo.
