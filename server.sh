#!/bin/bash
nc_port=1234                
target="Assignment 2"       
tmp=$(mktemp -d)           

trap 'pkill -P $$ 2>/dev/null; rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM

fail() { echo "Error: $*" >&2; echo "Error: $*"; }

IP=$(ifconfig | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | sed 's/addr://' | head -n 1)
if [ -z "$IP" ]; then
    echo "Error: could not find this machine's IP address with ifconfig"
    exit 1
fi

if ss -ltn | awk '$1 == "LISTEN" {print $4}' | grep -q ":$nc_port$"; then
    echo "Error: port $nc_port is already in use (is another server.sh running? stop it with Ctrl+C or: pkill nc)"
    exit 1
fi

handle_assignment() {
    url="https://www.sydney.edu.au/units/INFO1112/2026-S2C-ND-CC"
    json="assignment.json"

    if ! curl -sfL "$url" -o "$tmp/unit.html"; then
        fail "unable to reach $url"
        return
    fi
    html2text -width 500 "$tmp/unit.html" > "$tmp/unit.txt"
    grep -A2 -m1 "$target" "$tmp/unit.txt" >&2
    block=$(grep -A4 -m1 "$target" "$tmp/unit.txt" | tr '\n' ' ' | tr -s ' ')

    title=$(echo "$block" | grep -oE 'Assignment [0-9]+' | head -n 1)
    topic=$(echo "$block" | sed -nE 's/.*Programming task - (.*[A-Za-z]) +[0-9]+%.*/\1/p')
    due=$(echo "$block" | grep -oE 'Due date:? *[0-9]{1,2} [A-Za-z]{3} [0-9]{4} (at )?[0-9]{1,2}:[0-9]{2}' \
          | head -n 1 | sed -E 's/Due date:? *//; s/ at / /')
    pts=$(echo "$block" | grep -oE '[0-9]+%' | head -n 1 | tr -d '%')

    if [ -z "$title" ] || [ -z "$topic" ] || [ -z "$due" ] || [ -z "$pts" ]; then
        fail "could not read the assignment details from the unit page (page layout may have changed)"
        return
    fi

    jq -n \
        --arg title "$title" \
        --arg topic "$topic" \
        --arg due "$due" \
        --argjson points "$pts" \
        '{title: $title, topic: $topic, due_date: $due, points: $points}' > "$tmp/$json"

    if ! jq . "$tmp/$json" > /dev/null 2>&1; then
        fail "could not build valid JSON"
        return
    fi
    mv "$tmp/$json" "$json"
    echo "Created $json:" >&2
    cat "$json" >&2
}

handle_population() {
    url="https://dbr.abs.gov.au/processedData/csv/STE_1.csv"
    csv="$tmp/pop.csv"
    PNG="population.png"
    pop_data="$tmp/pop_data.csv"

    if ! curl -sfL "$url" -o "$csv"; then
        fail "could not download population data"
        return
    fi

    tr -d '\r' < "$csv" | awk -F, '
        NR == 1          { for (i = 4; i <= NF; i++) year[i] = $i; next }
        $1 == "ERP_P_20" { for (i = 4; i <= NF; i++) if ($i != "") print year[i] "," $i }
    ' > "$pop_data"

    latest_year=$(tail -n 1 "$pop_data" | cut -d, -f1)
    latest=$(tail -n 1 "$pop_data" | cut -d, -f2)
    if [ -z "$latest" ]; then
        fail "could not find the NSW population in the downloaded data"
        return
    fi
    echo "NSW population ($latest_year): $latest" >&2

    python3 - "$pop_data" "$tmp/$PNG" 2> "$tmp/py.err" <<'PY'

# AI acknowledgement: this plotting script was generated with DeepseekAI and then
# adapted (it now reads the year,population pairs that server.sh extracted with Bash).
import sys, csv
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

pairs_path, out_png = sys.argv[1], sys.argv[2]
xs, ys = [], []
with open(pairs_path) as f:
    for row in csv.reader(f):
        xs.append(int(row[0]))
        ys.append(int(row[1]))

plt.plot(xs, ys, marker="o")
plt.xlabel("Year")
plt.ylabel("Population")
plt.title("NSW population")
plt.tight_layout()
plt.savefig(out_png)
PY

    if [ ! -s "$tmp/$PNG" ]; then
        fail "plot generation failed: $(tail -n 1 "$tmp/py.err")"
        return
    fi
    mv "$tmp/$PNG" "$PNG"
    echo "Created $PNG" >&2
}

handle_whereami() {
    req="$1"
    pois_file="neighbours.json"
    IFS='|' read -r _ place dist <<< "$req"
    dist=${dist:-5000}

    if [[ "$place" =~ ^-?[0-9.]+,-?[0-9.]+$ ]]; then
        lat=${place%,*}
        lon=${place#*,}
    else
        geo=$(curl -sf -A "info1112-a2-student" -G "https://nominatim.openstreetmap.org/search" \
              --data-urlencode "q=$place" -d "format=json" -d "limit=1")
        lat=$(echo "$geo" | jq -r '.[0].lat // empty')
        lon=$(echo "$geo" | jq -r '.[0].lon // empty')
        if [ -z "$lat" ] || [ -z "$lon" ]; then
            fail "POI '$place' was not found"
            return
        fi
    fi

    query="[out:json][timeout:25];node(around:$dist,$lat,$lon)[\"name\"][\"tourism\"];out;"
    result=$(curl -sf "https://overpass-api.de/api/interpreter" --data-urlencode "data=$query")
    if [ -z "$result" ]; then
        fail "could not get neighbouring POIs (service unreachable)"
        return
    fi

    names=$(echo "$result" | jq -c '[.elements[].tags.name] | unique')
    jq -n --arg poi "$place" --argjson distance "$dist" --argjson neighbours "$names" \
        '{poi: $poi, distance_m: $distance, neighbours: $neighbours}' > "$tmp/$pois_file"
    mv "$tmp/$pois_file" "$pois_file"
    echo "Created $pois_file:" >&2
    cat "$pois_file" >&2
}


start_job() {
    outfile="$1"
    shift
    # Test case B: this client already has a job running -> reject
    if [ -e "$lock" ]; then
        fail "server is busy with another request from $client_ip - this request was rejected"
        return
    fi
    touch "$lock"
    # the job runs in the background (&); the lock file is removed when it is finished
    ( sleep "${TEST_DELAY:-0}"; "$@"; rm -f "$lock" ) > /dev/null < /dev/null &
    echo "OK: request accepted and running in the background."
    echo "When it has finished, download the result with:  echo 'get $outfile' | nc <server-ip> $nc_port > $outfile"
}

send_file() {
    case "$1" in
        assignment.json|population.png|neighbours.json) ;;
        *) fail "unknown file '$1' (available: assignment.json, population.png, neighbours.json)"; return ;;
    esac
    if [ ! -s "$1" ]; then
        fail "$1 is not ready yet (the job may still be running, or it failed - see the server screen)"
        return
    fi
    cat "$1"
}

handle_request() {
    read -r request || true                   
    request=${request%$'\r'}

    cat "$tmp/nc_info" >&2                     
    client_ip=$(awk '/Connection received/ {print $4}' "$tmp/nc_info")
    lock="$tmp/busy_$client_ip"

    if [ -z "$request" ]; then
        fail "empty request received"
    elif [[ "$request" == "get "* ]]; then
        send_file "${request#get }"
    elif [ "$request" = "assignment" ]; then
        start_job assignment.json handle_assignment
    elif [ "$request" = "population" ]; then
        start_job population.png handle_population
    elif [[ "$request" == "where am I"* ]]; then
        IFS='|' read -r _ place dist <<< "$request"
        if [ -z "$place" ]; then
            fail "usage: where am I|<place name or lat,lon>|<distance in metres>"
        elif ! [[ "${dist:-5000}" =~ ^[0-9]+$ ]]; then
            fail "distance must be a whole number of metres"
        else
            start_job neighbours.json handle_whereami "$request"
        fi
    else
        fail "invalid request '$request' (try: assignment, population, where am I|<place>|<metres>, or get <file>)"
    fi
}

mkfifo "$tmp/reply_pipe"

(
    sleep 0.5
    port=$(ss -ltn | awk '$1 == "LISTEN" {print $4}' | sed 's/.*://' | head -n 1)
    echo "The server is running at $IP, port=$port"
) &

while true; do
    nc -N -n -v -l "$nc_port" < "$tmp/reply_pipe" 2> "$tmp/nc_info" | handle_request > "$tmp/reply_pipe" &
    wait
done



