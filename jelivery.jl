using Dates
using Printf
using Random

# configuuracoes
const TOTAL_PEDIDOS  = 20
const MAX_WORKERS    = min(4, Threads.nthreads())
const SLEEP_GER      = 1.2
const SLEEP_PROC_MIN = 10.0
const SLEEP_PROC_MAX = 14.0
const SLEEP_CACHE    = 6.0
const BAR_WIDTH      = 22
const BAR_REFRESH    = 0.12

# cores
const R   = "\e[0m"
const B   = "\e[1m"
const DIM = "\e[2m"
const CYN = "\e[36m"
const YEL = "\e[33m"
const BLU = "\e[34m"
const GRN = "\e[32m"
const MAG = "\e[35m"
const RED = "\e[31m"
const WHT = "\e[97m"
const GRY = "\e[90m"

# cursor
ir_para(l, c=1)  = "\e[$(l);$(c)H"
apagar_linha()   = "\e[2K"
ocultar_cursor() = "\e[?25l"
mostrar_cursor() = "\e[?25h"

# tipos
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

# dados randorizados (para gerar os pedidos)
const PRIMEIROS  = ["Ana","Bruno","Carla","Diego","Elena","Felipe","Gabriela",
                    "Hugo","Isabela","João","Karina","Lucas","Marina","Nelson",
                    "Olivia","Paulo","Quezia","Rafael","Sofia","Thiago","Ursula",
                    "Vitor","Wendy","Xande","Yasmin","Zeca"]
const SOBRENOMES = ["Lima","Costa","Souza","Rocha","Martins","Alves","Nunes",
                    "Ferreira","Castro","Melo","Dias","Pereira","Oliveira",
                    "Santos","Carvalho","Ribeiro","Gomes","Araujo","Rodrigues","Mendes"]
const PRATOS     = ["Pizza Margherita","Pizza Calabresa","Pizza 4 Queijos",
                    "Hamburguer Artesanal","Hamburguer BBQ","Hamburguer Vegano",
                    "Temaki Salmão","Temaki Camarão","Hot Roll",
                    "Frango Grelhado","Frango à Parmegiana","Frango Xadrez",
                    "Açaí 500ml","Açaí 700ml","Pitaya Bowl",
                    "Prato Executivo","Marmita Fitness","Marmita Low Carb",
                    "Coxinha","Pastel de Queijo","Esfiha de Carne",
                    "Bowl Vegano","Bowl Proteico","Wrap Integral",
                    "Espetinho Misto","Lasanha Bolonhesa","Lasanha Vegana",
                    "Sushi 10 peças","Yakisoba","Pad Thai"]
const ACOMP      = ["Refrigerante","Suco Natural","Água com Gás","Chá Gelado",
                    "Batata Frita","Salada Caesar","Missoshiru","Onion Rings",
                    "Pão de Alho","Arroz Integral","Purê de Batata"]

nome_aleatorio(rng) = "$(rand(rng,PRIMEIROS)) $(rand(rng,SOBRENOMES))"
item_aleatorio(rng) = "$(rand(rng,1:3))x $(rand(rng,PRATOS)) + $(rand(rng,ACOMP))"

# status
const cache      = Dict{String,ResultadoPedido}()
const cache_lock = ReentrantLock()
const print_lock = ReentrantLock()

const n_chegando   = Threads.Atomic{Int}(0)
const n_preparando = Threads.Atomic{Int}(0)
const n_entregues  = Threads.Atomic{Int}(0)
const n_cache_hits = Threads.Atomic{Int}(0)

const term_rows = Ref{Int}(40)
const term_cols = Ref{Int}(80)

# colunas do kanban (listas de itens)

struct KanbanItem
    nome::String
    cache_hit::Bool   # caso seja cache mostra em roxo
end

const col_chegando   = KanbanItem[]
const col_preparando = KanbanItem[]
const col_entregues  = KanbanItem[]
const kanban_lock    = ReentrantLock()

function kanban_mover!(de::Vector{KanbanItem}, para::Vector{KanbanItem}, nome::String; cache_hit=false)
    lock(kanban_lock) do
        idx = findfirst(x -> x.nome == nome, de)
        if idx !== nothing
            deleteat!(de, idx)
        end
        push!(para, KanbanItem(nome, cache_hit))
    end
end

function kanban_adicionar!(col::Vector{KanbanItem}, nome::String; cache_hit=false)
    lock(kanban_lock) do
        push!(col, KanbanItem(nome, cache_hit))
    end
end

# layout do terminal
const DASH_LINES   = 4
const SEP_LINES    = 2
const BOTTOM_LINES = DASH_LINES + SEP_LINES + MAX_WORKERS

sep_top_row()      = term_rows[] - BOTTOM_LINES
dash_row(i::Int)   = sep_top_row() + i
mid_sep_row()      = sep_top_row() + DASH_LINES + 1
worker_row(i::Int) = mid_sep_row() + i
kanban_rows()      = max(4, sep_top_row() - 1)   # linhas disponíveis pro kanban (excl. linha 1 do header)

# renderizacao

truncar(s, n) = length(s) <= n ? s : s[1:n-1] * "…"
ts()          = Dates.format(now(), "HH:MM:SS")

function _barra(valor::Int, total::Int, larg::Int, cor::String)
    pct   = total > 0 ? clamp(valor/total, 0.0, 1.0) : 0.0
    cheio = round(Int, pct * larg)
    "$(cor)$(B)$("\u2588"^cheio)$(R)$(GRY)$("\u2591"^(larg-cheio))$(R)"
end


function _kanban_linha(items::Vector{KanbanItem}, idx::Int, col_x::Int, col_w::Int)
    if idx <= length(items)
        item = items[idx]
        nome_txt = truncar(item.nome, col_w - 4)
        cor  = item.cache_hit ? MAG : WHT
        icone = item.cache_hit ? "★ " : "· "
        conteudo = " $(cor)$(icone)$(nome_txt)$(R)"
        raw_len = 2 + length(icone) + length(nome_txt)  
        pad = max(0, col_w - raw_len)
        return conteudo * " "^pad
    else
        return " "^col_w
    end
end

function _flush_tela()
    buf  = IOBuffer()
    cols = term_cols[]
    rows = term_rows[]

    col_w   = max(10, (cols - 2) ÷ 3)
    k_rows  = kanban_rows()      # linhas de conteúdo do kanban
    sep_str = "$(GRY)$("─"^min(cols-1, cols))$(R)"

    hdr_cheg = truncar("  → CHEGANDO", col_w)
    hdr_prep = truncar("  ⚙ PREPARANDO", col_w)
    hdr_entr = truncar("  ✓ ENTREGUES", col_w)
    pad_c = col_w - length(hdr_cheg)
    pad_p = col_w - length(hdr_prep)
    pad_e = col_w - length(hdr_entr)
    hdr = "$(CYN)$(B)$(hdr_cheg)$(" "^pad_c)$(R)" *
          "$(GRY)|$(R)" *
          "$(YEL)$(B)$(hdr_prep)$(" "^pad_p)$(R)" *
          "$(GRY)|$(R)" *
          "$(GRN)$(B)$(hdr_entr)$(" "^pad_e)$(R)"
    print(buf, ir_para(1, 1), apagar_linha(), hdr)

  
    print(buf, ir_para(2, 1), apagar_linha(), "$(GRY)$("─"^col_w)┼$("─"^col_w)┼$("─"^col_w)$(R)")

    items_c, items_p, items_e = KanbanItem[], KanbanItem[], KanbanItem[]
    lock(kanban_lock) do
        append!(items_c, col_chegando)
        append!(items_p, col_preparando)
        append!(items_e, col_entregues)
    end

    reverse!(items_e)

    for row in 1:k_rows
        lc = _kanban_linha(items_c, row, 1,       col_w)
        lp = _kanban_linha(items_p, row, col_w+2, col_w)
        le = _kanban_linha(items_e, row, col_w*2+3, col_w)
        linha = lc * "$(GRY)|$(R)" * lp * "$(GRY)|$(R)" * le
        print(buf, ir_para(row + 2, 1), apagar_linha(), linha)
    end


    print(buf, ir_para(sep_top_row(), 1), apagar_linha(), sep_str)

  
    total = TOTAL_PEDIDOS
    cheg  = n_chegando[]
    prep  = n_preparando[]
    entr  = n_entregues[]
    hits  = n_cache_hits[]
    bw    = max(8, min(28, cols - 30))

    function dash_linha(icone, label, cor, valor, maximo, sufixo)
        bar = _barra(valor, maximo, bw, cor)
        cnt = "$(cor)$(B)$(lpad(valor,2))$(R)$(GRY)/$(maximo)$(R)"
        "  $(cor)$(B)$(icone) $(label)$(R)  $(bar)  $(cnt)  $(GRY)$(sufixo)$(R)"
    end

    print(buf, ir_para(dash_row(1),1), apagar_linha(),
        dash_linha("→","Chegando  ", CYN, cheg, total,       "na fila"))
    print(buf, ir_para(dash_row(2),1), apagar_linha(),
        dash_linha("⚙","Preparando", YEL, prep, MAX_WORKERS, "workers ativos"))
    print(buf, ir_para(dash_row(3),1), apagar_linha(),
        dash_linha("✓","Entregues ", GRN, entr, total,       "concluídos"))
    print(buf, ir_para(dash_row(4),1), apagar_linha(),
        dash_linha("★","Cache hit ", MAG, hits, total,       "via cache"))

 
    print(buf, ir_para(mid_sep_row(),1), apagar_linha(), sep_str)

    print(stdout, String(take!(buf)))
    flush(stdout)
end

# restarta
function redesenhar()
    lock(print_lock) do
        _flush_tela()
    end
end

# linha worker fixa (para não interferir no kanban e nas barras)
function fixo_worker(wid::Int, conteudo::String)
    lock(print_lock) do
        print(stdout, ir_para(worker_row(wid), 1), apagar_linha(), conteudo)
        flush(stdout)
    end
end

# barra worker
cor_prog(pct)  = pct < 0.35 ? BLU : pct < 0.70 ? YEL : GRN
fase_prog(pct) = pct < 0.20 ? "Iniciando..." :
                 pct < 0.45 ? "Cozinhando.." :
                 pct < 0.70 ? "Finalizando." :
                 pct < 0.90 ? "Embalando..." : "Pronto!     "

function linha_barra(wid::Int, pedido::Pedido, elapsed::Float64, dur::Float64)
    pct   = clamp(elapsed / dur, 0.0, 1.0)
    cor   = cor_prog(pct)
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
        "$(DIM)$(fase_prog(pct))$(R) $(GRY)ETA:$(eta)$(R)"
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

# setup terminal
function detectar_tamanho()
    try
        rows = parse(Int, strip(read(`tput lines`, String)))
        cols = parse(Int, strip(read(`tput cols`,  String)))
        return max(20, rows), max(60, cols)
    catch
        return 40, 80
    end
end

function setup_terminal()
    term_rows[], term_cols[] = detectar_tamanho()
    lock(print_lock) do
        print(stdout, "\e[2J", ir_para(1,1))
        for id in 1:MAX_WORKERS
            print(stdout, ir_para(worker_row(id), 1), apagar_linha(), linha_idle(id))
        end
        flush(stdout)
        _flush_tela()
    end
end

# gerador de pedidos
function gerar_pedidos(canal::Channel{Pedido}, n::Int)
    @async begin
        rng  = MersenneTwister(42 + n)
        pool = String[]
        while length(pool) < max(4, n - n÷3)
            nm = nome_aleatorio(rng)
            nm ∉ pool && push!(pool, nm)
        end
        nomes = copy(pool)
        while length(nomes) < n
            push!(nomes, rand(rng, pool))
        end
        shuffle!(rng, nomes)
        itens = [item_aleatorio(rng) for _ in 1:n]

        for i in 1:n
            pedido = Pedido(i, nomes[i], itens[i])
            put!(canal, pedido)
            Threads.atomic_add!(n_chegando, 1)
            kanban_adicionar!(col_chegando, pedido.nome)
            redesenhar()
            sleep(SLEEP_GER)
        end
        close(canal)
    end
end

# processando de pedidos (simula o preparo, atualiza o kanban e as barras)
function processar_pedido(pedido::Pedido, wid::Int)::ResultadoPedido
    Threads.atomic_sub!(n_chegando, 1)
    Threads.atomic_add!(n_preparando, 1)
    kanban_mover!(col_chegando, col_preparando, pedido.nome)
    redesenhar()

    cached   = lock(cache_lock) do
        haskey(cache, pedido.nome) ? cache[pedido.nome] : nothing
    end
    do_cache = cached !== nothing
    dur      = do_cache ? SLEEP_CACHE :
               SLEEP_PROC_MIN + rand()*(SLEEP_PROC_MAX - SLEEP_PROC_MIN)

    if do_cache
        Threads.atomic_add!(n_cache_hits, 1)
        lock(kanban_lock) do
            idx = findfirst(x -> x.nome == pedido.nome, col_preparando)
            if idx !== nothing
                col_preparando[idx] = KanbanItem(pedido.nome, true)
            end
        end
        redesenhar()
    end

    t0 = time()
    while (el = time() - t0) < dur
        fixo_worker(wid, linha_barra(wid, pedido, el, dur))
        sleep(BAR_REFRESH)
    end
    tempo_real = time() - t0

    fixo_worker(wid, linha_concluida(wid, pedido, tempo_real, do_cache))

    if !do_cache
        lock(cache_lock) do
            cache[pedido.nome] = ResultadoPedido(pedido, "Entregue", tempo_real, false)
        end
    end


    Threads.atomic_sub!(n_preparando, 1)
    Threads.atomic_add!(n_entregues, 1)
    kanban_mover!(col_preparando, col_entregues, pedido.nome; cache_hit=do_cache)
    redesenhar()

    sleep(0.35)
    fixo_worker(wid, linha_idle(wid))
    return ResultadoPedido(pedido, "Entregue", tempo_real, do_cache)
end

# workers
function worker(canal::Channel{Pedido}, id::Int)
    for pedido in canal
        processar_pedido(pedido, id)
    end
    fixo_worker(id, linha_idle(id))
end

# relatorio final
function relatorio_final(t_inicio::Float64)
    t = time() - t_inicio
    lock(print_lock) do
        print(stdout, ir_para(term_rows[]+1, 1))
        flush(stdout)
    end
    println()
    println("$(GRN)$(B)  --------  RELATÓRIO FINAL  --------  $(R)")
    println()
    println("  $(GRY)Pedidos entregues$(R)  $(GRN)$(B)$(n_entregues[])$(R)")
    println("  $(GRY)Cache hits       $(R)  $(MAG)$(B)$(n_cache_hits[])$(R)")
    println("  $(GRY)Workers          $(R)  $(WHT)$(B)$(MAX_WORKERS)$(R)")
    println("  $(GRY)Tempo total      $(R)  $(WHT)$(B)$(@sprintf("%.1f", t))s$(R)")
    println()
    println("$(GRN)$(B)  -----------------------------------  $(R)")
    println()
end

# main
function main()
    print(stdout, ocultar_cursor())
    setup_terminal()

    canal = Channel{Pedido}(TOTAL_PEDIDOS)
    t0    = time()
    gerar_pedidos(canal, TOTAL_PEDIDOS)
    tasks = [Threads.@spawn worker(canal, i) for i in 1:MAX_WORKERS]
    for t in tasks; wait(t); end

    print(stdout, mostrar_cursor())
    relatorio_final(t0)
end

main()