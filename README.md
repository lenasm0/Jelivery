# Jelivery

Sistema de delivery concorrente simulado em Julia, com interface visual no terminal em tempo real.

Múltiplos workers processam pedidos em paralelo, cada um em sua própria thread. O terminal exibe um kanban ao vivo com as três etapas dos pedidos, um dashboard com barras de progresso e as barras individuais de cada worker.


## Como funciona

Cada pedido passa por três etapas, visíveis no kanban:

| Etapa | Cor | Descrição |
|---|---|---|
| **Chegando** | Ciano | Pedido na fila, aguardando um worker livre |
| **Preparando** | Amarelo | Worker pegou o pedido e está processando |
| **Entregues** | Verde | Pedido concluído |

Pedidos de clientes que já pediram antes são detectados pelo **cache** e entregues mais rápido. Esses pedidos aparecem em **roxo** com o ícone `★` no kanban.

---

## Requisitos

- [Julia](https://julialang.org/downloads/) 1.9 ou superior
- Terminal com suporte a cores ANSI (Windows Terminal, iTerm2, terminal do macOS, qualquer terminal Linux moderno)

---

## Como rodar

### 1. Baixe o arquivo

Clone o repositório ou baixe `jelivery.jl` diretamente.

```bash
git clone https://github.com/seu-usuario/jelivery.git
cd jelivery
```

### 2. Rode com múltiplas threads

```bash
julia --threads 4 jelivery.jl
```

Substitua `4` pelo número de workers que quiser. O número de workers nunca ultrapassa o número de threads disponíveis na máquina.

### Windows (CMD ou PowerShell)

```cmd
julia --threads 4 jelivery.jl
```

> **Dica:** use o **PowerShell** em vez do CMD clássico para melhor suporte às cores e ao posicionamento de cursor.


## Configurações

Todas as configurações ficam no topo do arquivo `jelivery.jl` e podem ser alteradas livremente:

```julia
const TOTAL_PEDIDOS  = 20    # quantidade de pedidos simulados
const MAX_WORKERS    = min(4, Threads.nthreads())  # número máximo de workers
const SLEEP_GER      = 1.2   # intervalo entre chegada de pedidos (segundos)
const SLEEP_PROC_MIN = 10.0  # tempo mínimo de preparo (segundos)
const SLEEP_PROC_MAX = 14.0  # tempo máximo de preparo (segundos)
const SLEEP_CACHE    = 6.0   # tempo de entrega via cache (segundos)
const BAR_WIDTH      = 22    # largura das barras de progresso (caracteres)
const BAR_REFRESH    = 0.12  # frequência de atualização das barras (segundos)
```

## Conceitos demonstrados

- **Concorrência com threads** — cada worker roda em sua própria thread via `Threads.@spawn`
- **Comunicação entre threads** — pedidos são distribuídos por um `Channel`, que funciona como fila thread-safe
- **Exclusão mútua** — `ReentrantLock` protege o cache e a saída do terminal contra acesso simultâneo
- **Cache** — resultados de pedidos já processados são salvos em memória; pedidos do mesmo cliente são entregues mais rápido na segunda vez
- **Renderização por coordenadas absolutas** — a interface usa sequências ANSI para escrever em posições exatas do terminal, permitindo que o kanban, o dashboard e as barras de worker coexistam na tela sem conflito
