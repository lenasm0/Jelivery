using Dates
using Printf
using Random

# configuracao
const TOTAL_PEDIDOS  = 20
const MAX_WORKERS    = min(8, Threads.nthreads())
const SLEEP_GER      = 1.2          # intervalo de pedidos
const SLEEP_PROC_MIN = 10.0
const SLEEP_PROC_MAX = 14.0
const SLEEP_CACHE    = 6.0
const BAR_WIDTH      = 24
const BAR_REFRESH    = 0.12

# cores
const R   = "\e[0m"   # reset — volta ao estilo normal
const B   = "\e[1m"   # bold negrito
const DIM = "\e[2m"   # dimmed apagado, mais fraco
const CYN = "\e[36m"  # ciano, usado em pedidos chegando
const YEL = "\e[33m"  # amarelo, usado em pedidos sendo preparados
const BLU = "\e[34m"  # azul
const GRN = "\e[32m"  # verde. usado em pedidos entregues
const MAG = "\e[35m"  # rosa, usado em cache
const RED = "\e[31m"  # vermelho, usado em workers encerrando
const WHT = "\e[97m"  # branco brilhante
const GRY = "\e[90m"  # cinza escuro, textos secundários

# terminal
ir_para(l, c=1)    = "\e[$(l);$(c)H"
apagar_linha()      = "\e[2K"
salvar_cursor()     = "\e[s"
restaurar_cursor()  = "\e[u"
ocultar_cursor()    = "\e[?25l"
mostrar_cursor()    = "\e[?25h"

# tipo dados
struct Pedido
    id::Int
    nome::String
    descricao::String
end

struct ResultadoPedido
    pedido::Pedido
    status::String
    tempo_s::Float64
    do_cache::Bool
end

# dados aleatorios
const PRIMEIROS = ["Ana","Bruno","Carla","Diego","Elena","Felipe","Gabriela",
                   "Hugo","Isabela","João","Karina","Lucas","Marina","Nelson",
                   "Olivia","Paulo","Quezia","Rafael","Sofia","Thiago","Ursula",
                   "Vitor","Wendy","Xande","Yasmin","Zeca"]
const SOBRENOMES = ["Lima","Costa","Souza","Rocha","Martins","Alves","Nunes",
                    "Ferreira","Castro","Melo","Dias","Pereira","Oliveira",
                    "Santos","Carvalho","Ribeiro","Gomes","Araujo","Rodrigues","Mendes"]

const PRATOS = [
    "Pizza Margherita","Pizza Calabresa","Pizza 4 Queijos",
    "Hamburguer Artesanal","Hamburguer BBQ","Hamburguer Vegano",
    "Temaki Salmão","Temaki Camarão","Hot Roll",
    "Frango Grelhado","Frango à Parmegiana","Frango Xadrez",
    "Açaí 500ml","Açaí 700ml","Pitaya Bowl",
    "Prato Executivo","Marmita Fitness","Marmita Low Carb",
    "Coxinha","Pastel de Queijo","Esfiha de Carne",
    "Bowl Vegano","Bowl Proteico","Wrap Integral",
    "Espetinho Misto","Lasanha Bolonhesa","Lasanha Vegana",
    "Sushi 10 peças","Yakisoba","Pad Thai",
]
const ACOMP = [
    "Refrigerante","Suco Natural","Água com Gás","Chá Gelado",
    "Batata Frita","Salada Caesar","Missoshiru","Onion Rings",
    "Pão de Alho","Arroz Integral","Purê de Batata",
]

function nome_aleatorio(rng::AbstractRNG)
    "$(rand(rng, PRIMEIROS)) $(rand(rng, SOBRENOMES))"
end

function item_aleatorio(rng::AbstractRNG)
    qtd   = rand(rng, 1:3)
    prato = rand(rng, PRATOS)
    acomp = rand(rng, ACOMP)
    "$(qtd)x $(prato) + $(acomp)"
end

# status
const cache      = Dict{Int,ResultadoPedido}()  # salvar resultado 
const cache_lock = ReentrantLock()   # trava para evitar dois workers acessando o cache ao mesmo tempo
const print_lock = ReentrantLock()   # trava para evitar dois workers imprimindo ao mesmo tempo no cache

const n_chegando    = Threads.Atomic{Int}(0)   # na fila, ainda não pegos
const n_preparando  = Threads.Atomic{Int}(0)   # sendo processados agora
const n_entregues   = Threads.Atomic{Int}(0)   # concluídos
const n_cache_hits  = Threads.Atomic{Int}(0)

const term_rows = Ref{Int}(40)
const term_cols = Ref{Int}(80)

# layout
#
#  log de eventos
#  ────────────── separador ──────────────  
#  dashboard, onde fica os status             
#  ────────────── separador ──────────────  
#  workers trabalhando  
#
const DASH_LINES   = 4   # linhas do dashboard (chegando / fazendo / entregues / cache)
const SEP_LINES    = 2   
const BOTTOM_LINES = DASH_LINES + SEP_LINES + MAX_WORKERS

sep_top()           = term_rows[] - BOTTOM_LINES + 1
dash_row(i::Int)    = sep_top() + i            # i= 1..4 (status)
mid_sep_row()       = sep_top() + DASH_LINES + 1
worker_row(i::Int)  = mid_sep_row() + i        # i=1..MAX_WORKERS (barra de workers)

# oraganizacao do terminal
ts()          = Dates.format(now(), "HH:MM:SS")
truncar(s,n)  = length(s) <= n ? s : s[1:n-1]*"…"
strip_ansi(s) = replace(s, r"\e\[[0-9;]*m" => "")

function detectar_tamanho()
    try
        rows = parse(Int, strip(read(`tput lines`, String)))
        cols = parse(Int, strip(read(`tput cols`,  String)))
        return max(rows,20), max(cols,60)
    catch
        return 40, 80
    end
end


# o que vai aparecer no log 
function log_println(linha::String)
    sep = sep_top()
    lock(print_lock) do
        buf = IOBuffer()
        print(buf, salvar_cursor())
        print(buf, ir_para(sep - 1, 1))
        print(buf, "\e[1S")                 # scroll up dentro da scroll region
        print(buf, ir_para(sep - 1, 1))
        print(buf, apagar_linha(), linha)
        print(buf, restaurar_cursor())
        print(stdout, String(take!(buf)))
        flush(stdout)
    end
end

# reescreve a linha
function fixo_println(row::Int, conteudo::String)
    lock(print_lock) do
        buf = IOBuffer()
        print(buf, salvar_cursor())
        print(buf, ir_para(row, 1), apagar_linha(), conteudo)
        print(buf, restaurar_cursor())
        print(stdout, String(take!(buf)))
        flush(stdout)
    end
end

# dashboard

function barra_mini(valor::Int, total::Int, larg::Int, cor::String)
    pct   = total > 0 ? clamp(valor/total, 0.0, 1.0) : 0.0
    cheio = round(Int, pct * larg)
    "$(cor)$(B)$("\u2588"^cheio)$(R)$(GRY)$("\u2591"^(larg-cheio))$(R)"
end

function redesenhar_dashboard()
    cols  = term_cols[]
    total = TOTAL_PEDIDOS
    cheg  = n_chegando[]
    prep  = n_preparando[]
    entr  = n_entregues[]
    hits  = n_cache_hits[]
    bw    = max(10, min(30, cols - 42))   # largura da barra adaptada à coluna

    # linha 1 — chegando
    fixo_println(dash_row(1), string(
        " $(CYN)$(B)  Chegando$(R)  ",
        barra_mini(cheg, total, bw, CYN),
        "  $(CYN)$(B)$(lpad(cheg, 2))$(R)$(GRY)/$(total)$(R)"
    ))
    # linha 2 — preparando
    fixo_println(dash_row(2), string(
        " $(YEL)$(B) Preparando$(R)  ",
        barra_mini(prep, MAX_WORKERS, bw, YEL),
        "  $(YEL)$(B)$(lpad(prep, 2))$(R)$(GRY)/$(MAX_WORKERS) workers$(R)"
    ))
    # linha 3 — entregues
    fixo_println(dash_row(3), string(
        " $(GRN)$(B) Entregues$(R)  ",
        barra_mini(entr, total, bw, GRN),
        "  $(GRN)$(B)$(lpad(entr, 2))$(R)$(GRY)/$(total)$(R)"
    ))
    # linha 4 — cache hits
    fixo_println(dash_row(4), string(
        " $(MAG)$(B)  Cache hit$(R)  ",
        barra_mini(hits, total, bw, MAG),
        "  $(MAG)$(B)$(lpad(hits, 2))$(R)$(GRY) pedidos via cache$(R)"
    ))
end

# workers

cor_prog(pct)  = pct < 0.35 ? BLU : pct < 0.70 ? YEL : GRN
fase_prog(pct) = pct < 0.20 ? "Iniciando..." :
                 pct < 0.45 ? "Cozinhando.." :
                 pct < 0.70 ? "Finalizando." :
                 pct < 0.90 ? "Embalando..." : "Pronto!     "

function linha_barra(wid::Int, pedido::Pedido, elapsed::Float64, dur::Float64)
    pct   = clamp(elapsed / dur, 0.0, 1.0)
    cor   = cor_prog(pct)
    fase  = fase_prog(pct)
    cheio = round(Int, pct * BAR_WIDTH)
    eta   = @sprintf("%2.0fs", max(0.0, dur - elapsed))
    string(
        " $(GRY)[W$(wid)]$(R) ",
        "$(YEL)$(B)#$(lpad(pedido.id,3,'0'))$(R) ",
        "$(DIM)$(truncar(pedido.nome,12))$(R) ",
        "$(cor)$(B)[$(R)",
        "$(cor)$(B)$("\u2588"^cheio)$(R)$(GRY)$("\u2591"^(BAR_WIDTH-cheio))$(R)",
        "$(cor)$(B)]$(R) ",
        "$(cor)$(B)$(@sprintf("%3d", round(Int,pct*100)))%$(R) ",
        "$(DIM)$(fase)$(R) $(GRY)ETA:$(eta)$(R)"
    )
end

function linha_concluida(wid::Int, pedido::Pedido, tempo::Float64, do_cache::Bool)
    via = do_cache ? "$(MAG)$(B)cache$(R)" : "$(GRN)$(B)preparo$(R)"
    string(
        " $(GRY)[W$(wid)]$(R) ",
        "$(GRN)$(B)#$(lpad(pedido.id,3,'0'))$(R) ",
        "$(DIM)$(truncar(pedido.nome,12))$(R) ",
        "$(GRN)$(B)[$("\u2588"^BAR_WIDTH)]$(R) ",
        "$(GRN)$(B)100% ✓$(R) via $(via) $(GRY)$(@sprintf("%.1f",tempo))s$(R)"
    )
end

linha_idle(wid::Int) = " $(GRY)[W$(wid)]$(DIM) aguardando...$(R)"

# separadores

function desenhar_separadores()
    cols = term_cols[]
    sep  = "$(GRY)$(DIM)$("─"^min(cols-1, 78))$(R)"
    fixo_println(sep_top(),     sep)
    fixo_println(mid_sep_row(), sep)
end

# logs de eventos

function log_evento(icone::String, cor::String, msg::String)
    log_println(" $(cor)$(B)$(icone)$(R) $(GRY)$(ts())$(R)  $(msg)")
end

# terminal

function setup_terminal()
    term_rows[], term_cols[] = detectar_tamanho()
    sep = sep_top()
    lock(print_lock) do
        buf = IOBuffer()
        print(buf, "\e[2J", ir_para(1,1))             # limpa tela
        print(buf, "\e[1;$(sep-1)r")                  # scroll region
        # separadores
        cols = term_cols[]
        linha_sep = "$(GRY)$(DIM)$("─"^min(cols-1,78))$(R)"
        print(buf, ir_para(sep_top(), 1),     apagar_linha(), linha_sep)
        print(buf, ir_para(mid_sep_row(), 1), apagar_linha(), linha_sep)
        # workers idle
        for id in 1:MAX_WORKERS
            print(buf, ir_para(worker_row(id), 1), apagar_linha(), linha_idle(id))
        end
        # posiciona cursor no log
        print(buf, ir_para(sep-1, 1))
        print(stdout, String(take!(buf)))
        flush(stdout)
    end
    # dashboard inicial
    redesenhar_dashboard()
end

# banner
function banner()
    for l in [
        "",
        "$(CYN)$(B) ----------- JELIVERY ----------- $(R)",
        "",
        "  $(GRY)Threads$(R) $(WHT)$(B)$(Threads.nthreads())$(R)   $(GRY)Workers$(R) $(WHT)$(B)$(MAX_WORKERS)$(R)   $(GRY)Pedidos$(R) $(WHT)$(B)$(TOTAL_PEDIDOS)$(R)   $(GRY)Preparo$(R) $(DIM)$(round(Int,SLEEP_PROC_MIN))–$(round(Int,SLEEP_PROC_MAX))s$(R)",
        "",
    ]
        log_println(l)
    end
end

# gerador
function gerar_pedidos(canal::Channel{Pedido}, n::Int)
    @async begin
        rng = MersenneTwister(42 + n)   # seed reproduzível mas diferente p/ cada run
        # gera todos os pedidos antecipadamente para garantir unicidade
        nomes = String[]
        while length(nomes) < n
            nm = nome_aleatorio(rng)
            nm ∉ nomes && push!(nomes, nm)
        end
        itens = [item_aleatorio(rng) for _ in 1:n]

        for i in 1:n
            pedido = Pedido(i, nomes[i], itens[i])
            put!(canal, pedido)
            Threads.atomic_add!(n_chegando, 1)
            redesenhar_dashboard()
            log_evento("→", CYN, "Pedido $(B)#$(lpad(i,3,'0'))$(R) de $(YEL)$(B)$(nomes[i])$(R) entrou na fila")
            sleep(SLEEP_GER)
        end
        close(canal)
    end
end

# processar
function processar_pedido(pedido::Pedido, wid::Int)::ResultadoPedido
    # retira da fila de chegando, coloca em preparando
    Threads.atomic_sub!(n_chegando, 1)
    Threads.atomic_add!(n_preparando, 1)
    redesenhar_dashboard()

    cached   = lock(cache_lock) do
        haskey(cache, pedido.id) ? cache[pedido.id] : nothing
    end
    do_cache = cached !== nothing
    dur      = do_cache ? SLEEP_CACHE :
               SLEEP_PROC_MIN + rand()*(SLEEP_PROC_MAX - SLEEP_PROC_MIN)

    if do_cache
        Threads.atomic_add!(n_cache_hits, 1)
        redesenhar_dashboard()
        log_evento("★", MAG, "Cache hit  $(B)#$(lpad(pedido.id,3,'0'))$(R) → W$(wid) $(DIM)(~$(round(Int,dur))s)$(R)")
    else
        log_evento("▶", BLU, "Iniciando  $(B)#$(lpad(pedido.id,3,'0'))$(R) → W$(wid) $(DIM)(~$(round(Int,dur))s)$(R)")
    end

    t0 = time()
    while (el = time() - t0) < dur
        fixo_println(worker_row(wid), linha_barra(wid, pedido, el, dur))
        sleep(BAR_REFRESH)
    end
    tempo_real = time() - t0

    fixo_println(worker_row(wid), linha_concluida(wid, pedido, tempo_real, do_cache))

    if !do_cache
        lock(cache_lock) do
            cache[pedido.id] = ResultadoPedido(pedido, "Entregue", tempo_real, false)
        end
    end

    Threads.atomic_sub!(n_preparando, 1)
    Threads.atomic_add!(n_entregues, 1)
    redesenhar_dashboard()
    log_evento("✓", GRN, "Entregue   $(B)#$(lpad(pedido.id,3,'0'))$(R) $(DIM)$(pedido.nome)$(R)  $(GRN)$(B)$(@sprintf("%.1f",tempo_real))s$(R)")

    sleep(0.35)
    fixo_println(worker_row(wid), linha_idle(wid))
    return ResultadoPedido(pedido, "Entregue", tempo_real, do_cache)
end

# workers
function worker(canal::Channel{Pedido}, id::Int)
    log_evento("●", GRN, "Worker $(B)W$(id)$(R) online  $(DIM)thread #$(Threads.threadid())$(R)")
    for pedido in canal
        processar_pedido(pedido, id)
    end
    log_evento("○", RED, "Worker $(B)W$(id)$(R) encerrado")
    fixo_println(worker_row(id), linha_idle(id))
end

# relatorio
function relatorio_final(t_inicio::Float64)
    t = time() - t_inicio
    lock(print_lock) do
        print(stdout, "\e[r")                         # remove scroll region
        print(stdout, ir_para(term_rows[]+1, 1))
        flush(stdout)
    end
    println()
    println("$(GRN)$(B) ----------- RELATÓRIO FINAL ----------- $(R)")
    println()
    println("  $(GRY)Pedidos entregues$(R)  $(GRN)$(B)$(n_entregues[])$(R)")
    println("  $(GRY)Cache hits       $(R)  $(MAG)$(B)$(n_cache_hits[])$(R)")
    println("  $(GRY)Workers          $(R)  $(WHT)$(B)$(MAX_WORKERS)$(R)")
    println("  $(GRY)Tempo total      $(R)  $(WHT)$(B)$(@sprintf("%.1f", t))s$(R)")
    println()
    println("$(GRN)$(B) ------------------------------- $(R)")
    println()
end

# main
function main()
    print(stdout, ocultar_cursor())
    setup_terminal()
    banner()

    canal = Channel{Pedido}(TOTAL_PEDIDOS)
    t0    = time()
    gerar_pedidos(canal, TOTAL_PEDIDOS)
    tasks = [Threads.@spawn worker(canal, i) for i in 1:MAX_WORKERS]
    for t in tasks; wait(t); end

    print(stdout, mostrar_cursor())
    relatorio_final(t0)
end

main()