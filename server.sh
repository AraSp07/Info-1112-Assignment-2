#!/bin/bash
nc_port=1234                
pool=16                      
target="Assignment 2"        

fail() { echo "Error: $*" >&2; echo "Error: $*"; }

IP=$(ifconfig | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | sed 's/addr://' | head -n 1)
if [ -z "$IP" ]; then
    echo "Error: could not find this machine's IP address with ifconfig"
    exit 1
fi

if ss -ltn | grep -q ":$nc_port "; then
    echo "Error: port $nc_port is already in use (is another server.sh still running? stop it with Ctrl+C, or run: pkill -f server.sh; pkill nc)"
    exit 1
fi

tmp=$(mktemp -d)             

cleanup() {
    pkill -P $$ 2>/dev/null
    pkill -f "nc -N -n -v -l $nc_port" 2>/dev/null
    rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

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

# AI acknowledgement: this plotting script was generated with DeepseekAI 
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
    pois_file="neighbours.json"
    poi_url="https://maps.six.nsw.gov.au/arcgis/rest/services/public/NSW_POI/MapServer/0/query"
    poi_name=""                                

    if [[ "$place" =~ ^-?[0-9.]+,-?[0-9.]+$ ]]; then
        # the client sent coordinates:  latitude,longitude
        lat=${place%,*}
        lon=${place#*,}
    else
        name_sql=${place//\'/\'\'}
        name_sql=${name_sql^^}
        lat=""
        lon=""
        for condition in "poiname='$name_sql'" "poiname LIKE '%$name_sql%'"; do
            found=$(curl -sfG "$poi_url" \
                --data-urlencode "where=$condition" \
                -d "outFields=poiname" -d "returnGeometry=true" -d "outSR=4326" \
                -d "resultRecordCount=1" -d "f=json") || { fail "could not reach the NSW POI service"; return; }
            lat=$(echo "$found" | jq -r '.features[0].geometry.y // empty')
            lon=$(echo "$found" | jq -r '.features[0].geometry.x // empty')
            poi_name=$(echo "$found" | jq -r '.features[0].attributes.poiname // empty')
            [ -n "$lat" ] && break
        done
        if [ -z "$lat" ] || [ -z "$lon" ]; then
            fail "POI '$place' was not found in the NSW Points of Interest data"
            return
        fi
    fi
    result=$(curl -sfG "$poi_url" \
        --data-urlencode "geometry=$lon,$lat" -d "geometryType=esriGeometryPoint" -d "inSR=4326" \
        -d "spatialRel=esriSpatialRelIntersects" -d "distance=$dist" -d "units=esriSRUnit_Meter" \
        -d "where=1=1" -d "outFields=poiname,poitype" -d "returnGeometry=false" \
        -d "resultRecordCount=1000" -d "f=json") || { fail "could not reach the NSW POI service"; return; }

    names=$(echo "$result" | jq -c --arg self "$poi_name" \
            '[.features[].attributes.poiname] | map(select(. != null and . != $self)) | unique' 2> /dev/null)
    if [ -z "$names" ]; then
        fail "the NSW POI service did not return a list of POIs: $(echo "$result" | head -c 200)"
        return
    fi
    if [ "$(echo "$result" | jq -r '.exceededTransferLimit // false')" = "true" ]; then
        echo "Note: more than 1000 POIs found - the list is limited to the first 1000" >&2
    fi

    jq -n --arg poi "$place" --argjson distance "$dist" --argjson neighbours "$names" \
        '{poi: $poi, distance_m: $distance, count: ($neighbours | length), neighbours: $neighbours}' \
        > "$tmp/$pois_file"
    mv "$tmp/$pois_file" "$pois_file"
    echo "Created $pois_file:" >&2
    cat "$pois_file" >&2
}

run_job() {
    outfile="$1"                       
    job="$2"                           
    if [ -s "$lock" ] && kill -0 "$(cat "$lock")" 2>/dev/null; then
        fail "server is busy with another request from $client_ip - this request was rejected"
        return
    fi
    echo "$BASHPID" > "$lock"           
    rm -f "$outfile"
    sleep "${TEST_DELAY:-0}"            # for testing only: TEST_DELAY=10 bash server.sh
    $job
    rm -f "$lock"                       
    if [ -s "$outfile" ]; then
        cat "$outfile"                 
    fi
}

read_poi_request() {
    poi="$1"
    if echo "$poi" | grep -qi '^where am i'; then
        poi=$(echo "$poi" | cut -c11- | sed 's/^[?:| ]*//')
    fi

    dist=""
    if echo "$poi" | grep -qi 'distance *= *[0-9]'; then
        dist=$(echo "$poi" | grep -oiE 'distance *= *[0-9]+' | grep -oE '[0-9]+')
        poi=$(echo "$poi" | sed -E 's/[Dd]istance *= *[0-9]+//')
    elif echo "$poi" | grep -q '|'; then
        dist=$(echo "$poi" | awk -F'|' '{print $NF}' | tr -d ' ')
        poi=$(echo "$poi" | sed 's/|[^|]*$//')
    fi
    if [ -z "$dist" ]; then dist=5000; fi
    place=$(echo "$poi" | tr -d '|' | sed 's/^ *//; s/ *$//')

    if echo "$place" | grep -qE '^-?[0-9.]+ *, *-?[0-9.]+$'; then
        place=$(echo "$place" | tr -d ' ' | awk -F, '{ if ($1 > 0 && $2 < 0) print $2 "," $1; else print $1 "," $2 }')
    fi
}

handle_request() {
    id="$1"
    read -r request                                                     
    request=$(echo "$request" | tr -d '\r' | sed 's/^ *//; s/ *$//')   
    lower=$(echo "$request" | tr 'A-Z' 'a-z')
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if [ -s "$tmp/ip_$id" ]; then break; fi
        sleep 0.05
    done
    if [ ! -s "$tmp/ip_$id" ]; then exit 0; fi

    client_ip=$(cat "$tmp/ip_$id")
    lock="$tmp/busy_$client_ip"

    if [ "$lower" = "assignment" ] || [ "$lower" = "asssignment" ]; then   # (the rubric's example has 3 s's)
        run_job assignment.json handle_assignment
    elif [ "$lower" = "population" ]; then
        run_job population.png handle_population
    else
        read_poi_request "$request"
        if [ -z "$place" ] || ! echo "$dist" | grep -qE '^[0-9]+$'; then
            fail "send: assignment, population, or a POI name or lat,lon with an optional distance in metres, e.g. FISHER LIBRARY SYDNEY UNIVERSITY|5000"
        else
            run_job neighbours.json handle_whereami
        fi
    fi
}

on_nc_message() {
    id="$1"
    while read -r line; do
        case "$line" in
            "Listening on"*)
                if [ "$id" = "init1" ]; then echo "$line" > "$tmp/listening_line"; fi ;;
            "Connection received"*)
                echo "$line" | awk '{print $4}' > "$tmp/ip_$id"       
                echo "$line" >&2                                      
                serve_one "$BASHPID" > /dev/null < /dev/null &        
                ;;
            *) echo "$line" >&2 ;;                                    
        esac
    done
}

serve_one() {
    id="$1"
    mkfifo "$tmp/pipe_$id" "$tmp/msg_$id"
    on_nc_message "$id" < "$tmp/msg_$id" &
    nc -N -n -v -l "$nc_port" < "$tmp/pipe_$id" 2> "$tmp/msg_$id" | handle_request "$id" > "$tmp/pipe_$id"
    rm -f "$tmp/pipe_$id" "$tmp/msg_$id"
}

i=1
while [ "$i" -le "$pool" ]; do
    serve_one "init$i" > /dev/null < /dev/null &
    i=$((i + 1))
done

port=$(ss -ltnp | grep '"nc"' | awk '{print $4}' | sed 's/.*://' | head -n 1)
echo "The server is running at $IP, port=$port"
cat "$tmp/listening_line" >&2

while true; do
    sleep 1
done
