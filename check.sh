#!/usr/bin/env bash
# Проверяет публичные vless-ключи реальным запросом через sing-box (параллельно)
# и пишет рабочие в data/good.txt. Запускается в GitHub Actions, но работает и локально.
#
# Нужны: bash, curl, jq, xargs (GNU), sing-box (путь в $SB или в PATH)
# Результат: data/good.txt (ссылки, быстрые первыми), data/good.tsv, data/status.json

set -u

SOURCES=${SOURCES:-"https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/main/BLACK_VLESS_RUS.txt"}
USE_LISTS=${USE_LISTS:-1}
USE_CHECKER=${USE_CHECKER:-1}
CHECKER_URL=${CHECKER_URL:-https://tiagorrg.github.io/vless-checker/keys.json}
# группы из keys.json: страны, other_countries, russia и w_* (белые списки)
CHECKER_GROUPS=${CHECKER_GROUPS:-"germany finland netherlands sweden poland baltics other_countries"}
JOBS=${JOBS:-16}                 # сколько ключей проверяем одновременно
MAX_KEYS=${MAX_KEYS:-600}        # максимум ключей за прогон (случайная выборка)
KEEP=${KEEP:-60}                 # сколько ключей оставить в итоговом списке
PER_HOST=${PER_HOST:-2}          # не больше стольких ключей на один хост:порт
TEST_URL=${TEST_URL:-http://cp.cloudflare.com/generate_204}
CURL_TIMEOUT=${CURL_TIMEOUT:-10}
BASE_PORT=${BASE_PORT:-20000}    # локальные SOCKS-порты: BASE_PORT + номер ключа
OUT_DIR=${OUT_DIR:-data}
SB=${SB:-$(command -v sing-box)}
export JOBS TEST_URL CURL_TIMEOUT BASE_PORT SB

# значение параметра из $QUERY
getq() {
    printf '%s' "$QUERY" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n1
}

# разбор ссылки -> uuid host port QUERY; return 1 если не подходит
parse() {
    local rest hq hostport
    rest=${1#vless://}
    rest=${rest%%#*}
    uuid=${rest%%@*}
    hq=${rest#*@}
    hostport=${hq%%\?*}
    QUERY=
    case $hq in *\?*) QUERY=${hq#*\?} ;; esac
    port=${hostport##*:}
    host=${hostport%:*}
    host=${host#\[}
    host=${host%\]}
    case $port in '' | *[!0-9]*) return 1 ;; esac
    [ -n "$uuid" ] && [ -n "$host" ] || return 1
    # транспорты, которые sing-box не умеет (xhttp, kcp, quic...) - пропускаем
    case $(getq type) in '' | tcp | ws | grpc | httpupgrade) ;; *) return 1 ;; esac
    [ "$(getq headerType)" = http ] && return 1
    return 0
}

# конфиг sing-box для ключа; локальный SOCKS-порт берётся из $LPORT
mkcfg() {
    jq -n --arg uuid "$uuid" --arg host "$host" --argjson port "$port" \
        --arg sec "$(getq security)" --arg sni "$(getq sni)" --arg fp "$(getq fp)" \
        --arg pbk "$(getq pbk)" --arg sid "$(getq sid)" --arg flow "$(getq flow)" \
        --arg type "$(getq type)" --arg path "$(getq path)" \
        --arg hhost "$(getq host)" --arg svc "$(getq serviceName)" \
        --argjson lport "$LPORT" '
    def hex: explode | map(if . >= 97 then . - 87 elif . >= 65 then . - 55 else . - 48 end) | .[0] * 16 + .[1];
    def dec: split("%") | .[0] + (.[1:] | map(try (([.[0:2] | hex] | implode) + .[2:]) catch ("%" + .)) | join(""));
    ($path | dec) as $path | ($hhost | dec) as $hhost |
    {log: {level: "error"},
     inbounds: [{type: "socks", listen: "127.0.0.1", listen_port: $lport}],
     outbounds: [
       ({type: "vless", tag: "p", server: $host, server_port: $port, uuid: $uuid}
        + (if $flow != "" then {flow: $flow} else {} end)
        + (if $sec == "reality" or $sec == "tls" then
             {tls: ({enabled: true, server_name: (if $sni != "" then $sni else $host end)}
                + (if $fp != "" then {utls: {enabled: true, fingerprint: $fp}} else {} end)
                + (if $sec == "reality" then {reality: {enabled: true, public_key: $pbk, short_id: $sid}} else {} end))}
           else {} end)
        + (if $type == "ws" then
             {transport: ({type: "ws", path: (if $path != "" then $path else "/" end)}
                + (if $hhost != "" then {headers: {Host: $hhost}} else {} end))}
           elif $type == "grpc" then {transport: {type: "grpc", service_name: $svc}}
           elif $type == "httpupgrade" then {transport: {type: "httpupgrade", path: $path, host: $hhost}}
           else {} end))
     ]}'
}

# режим для xargs: проверить один ключ. Аргумент: "номер<TAB>ссылка".
# Если ключ рабочий, печатает "время<TAB>хост:порт<TAB>ссылка".
probe_one() {
    local idx=${1%%$'\t'*} link=${1#*$'\t'} dir pid res
    parse "$link" || return 0
    LPORT=$((BASE_PORT + idx))
    dir=$(mktemp -d)
    mkcfg >"$dir/c.json" 2>/dev/null || { rm -rf "$dir"; return 0; }
    "$SB" run -c "$dir/c.json" >/dev/null 2>&1 &
    pid=$!
    for _ in 1 2 3 4 5 6; do
        (exec 3<>"/dev/tcp/127.0.0.1/$LPORT") 2>/dev/null && break
        sleep 0.5
    done
    res=$(curl -s -o /dev/null -m "$CURL_TIMEOUT" --socks5-hostname "127.0.0.1:$LPORT" \
        -w '%{http_code} %{time_total}' "$TEST_URL" 2>/dev/null)
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -rf "$dir"
    case $res in 204*) printf '%s\t%s:%s\t%s\n' "${res#* }" "$host" "$port" "$link" ;; esac
    return 0
}

if [ "${1:-}" = probe ]; then
    probe_one "$2"
    exit 0
fi

# ---------- основной прогон ----------

[ -x "$SB" ] || { echo "sing-box не найден" >&2; exit 1; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT_DIR"

# 1. собрать ключи из источников
: >"$WORK/lists.txt"
: >"$WORK/checker.txt"
if [ "$USE_LISTS" = 1 ]; then
    for u in $SOURCES; do
        curl -fsSL -m 30 "$u" || echo "не скачался: $u" >&2
        echo
    done | tr -d '\r' | grep '^vless://' | sort -u >"$WORK/lists.txt"
    echo "из списков: $(wc -l <"$WORK/lists.txt") ключей"
fi
if [ "$USE_CHECKER" = 1 ]; then
    if curl -fsSL -m 30 "$CHECKER_URL" >"$WORK/checker.json" 2>/dev/null; then
        # у каждой группы есть top10[].key; other_countries вложена на уровень глубже
        jq -r --arg groups "$CHECKER_GROUPS" '
            def ks: if type == "object" and has("top10") then .top10[].key
                    elif type == "object" then (.[] | select(type == "object") | ks)
                    else empty end;
            ($groups | split(" ")) as $g | $g[] as $n | (.[$n] // empty) | ks' \
            "$WORK/checker.json" 2>/dev/null | tr -d '\r' | grep '^vless://' |
            awk '!s[$0]++' >"$WORK/checker.txt"
        echo "из vless-checker: $(wc -l <"$WORK/checker.txt") ключей"
    else
        echo "vless-checker недоступен" >&2
    fi
fi
cat "$WORK/checker.txt" "$WORK/lists.txt" | awk '!s[$0]++' >"$WORK/all.txt"
total=$(wc -l <"$WORK/all.txt")
[ "$total" -gt 0 ] || { echo "ключей нет, выходим без изменений" >&2; exit 0; }

# 2. случайная выборка и нумерация (номер задаёт локальный порт)
awk 'BEGIN { srand() } { print rand() "\t" $0 }' "$WORK/all.txt" | sort | cut -f2- |
    head -n "$MAX_KEYS" | awk '{ printf "%d\t%s\n", NR, $0 }' >"$WORK/numbered.txt"
tested=$(wc -l <"$WORK/numbered.txt")
echo "проверяю $tested ключей в $JOBS потоков"

# 3. параллельная проверка через sing-box
tr '\n' '\0' <"$WORK/numbered.txt" | xargs -0 -P "$JOBS" -n1 bash "$0" probe >"$WORK/ok.tsv"
ok=$(wc -l <"$WORK/ok.tsv")
echo "рабочих: $ok из $tested"

# 4. сортировка по времени ответа, не больше PER_HOST ключей на хост:порт, не больше KEEP
sort -n -k1,1 "$WORK/ok.tsv" | awk -F'\t' -v n="$PER_HOST" 'c[$2]++ < n' | head -n "$KEEP" >"$WORK/final.tsv"
kept=$(wc -l <"$WORK/final.tsv")

if [ "$kept" -eq 0 ]; then
    echo "рабочих ключей нет, прежние данные остаются" >&2
    exit 0
fi

cut -f3 "$WORK/final.tsv" >"$OUT_DIR/good.txt"
awk -F'\t' '{ name = $3; sub(/^[^#]*#?/, "", name); print $1 "\t" $2 "\t" name }' "$WORK/final.tsv" >"$OUT_DIR/good.tsv"
jq -n --arg t "$(date -u '+%Y-%m-%d %H:%M UTC')" --argjson total "$total" \
    --argjson tested "$tested" --argjson ok "$ok" --argjson kept "$kept" \
    '{updated_at: $t, source_total: $total, tested: $tested, ok: $ok, kept: $kept}' >"$OUT_DIR/status.json"
echo "записано $kept ключей в $OUT_DIR/good.txt"
