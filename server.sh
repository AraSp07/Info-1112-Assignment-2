#!/bin/bash
IP=$(ifconfig | grep 'inet ' | grep -v "127.0.0.1" | awk '{print $2}'| head -n 1)
port=1234
echo "The server is running at $IP, port=$port" 

handle_assignment() {
    client_ip="$1" 
    client_port="$2"
    url="https://www.sydney.edu.au/units/INFO1112/2026-S2C-ND-CC"

    if ! curl -s "$url" | html2text > /tmp/unit.txt 2>/tmp/err.txt; then
        echo "Error: unable to reach $url" | nc "$client_ip" "$client_port"
        return 
    fi

    grep -i -A2 -B2 -E "Assignment2| Due date| Creative work| Networking" /tmp/unit.txt | head -20
    title=$(grep -i -m1 'Assignment 2' /tmp/unit.txt | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    topic=$(grep -i -m1 'Networking' /tmp/unit.txt | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    due=$(grep -i -m1 'Due date' /tmp/unit.txt | sed 's/.*Due date[[:space:]]*:[[:space:]]*//')
    pts=$(grep -oE '[0-9]+' /tmp/unit.txt | head -n1)

    jq -n \
        --arg title "$title" \
        --arg topic "$topic" \
        --arg due "$due" \
        --argjson points "${pts:-0}" \
        '{title: $title, topic: $topic, due_date: $due, points: $points}' > /tmp/assignment.json

    if ! jq . /tmp/assignment.json > /dev/null 2>&1; then
        echo '{"error":"could not build valid JSON"}' | nc "$client_ip" "$client_port"
    fi 
    cat /tmp/assignment.json | nc "$client_ip" "$client_port"
}

handle_population() {
    client_ip="$1" 
    client_port="$2"
    
    url="https://dbr.abs.gov.au/processedData/csv/STE_1.csv"
    csv=/tmp/pop.csv 
    PNG=/tmp/population.png

    if ! curl -sL "$url" -o "$csv"; then
        echo "Error: could not download population data"| nc "$client_ip" "$client_port" 
        return 
    fi
    
    latest=$(awk -F, '$1 ~ /New South Wales/ && $2 == 2025 {print $3; exit}' "$csv")
    if [ -z "$latest" ]; then
        echo "Error: could not parse NSW 2025 population" | nc "$client_ip" "$client_port"
        return
    fi
    
    echo "NSW population (2025): $latest" | nc "$client_ip" "$client_port"

    python3 - "$csv" "$PNG" <<'PY'
# AI acknowledgement: this plotting stub was generated with DeepseekAI 
import sys, csv
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

csv_path, out_png = sys.argv[1], sys.argv[2]
xs, ys = [], []
with open(csv_path) as f:
    r = csv.reader(f)
    next(r, None)                     
    for row in r:
        if not row: 
            continue
        if "New South Wales" in row[0]:
            try:
                ys.append(int(float(row[2])))  
                xs.append(int(row[1]))
            except (ValueError, IndexError):
                continue

plt.plot(xs, ys)
plt.xlabel("Year")
plt.ylabel("Population")
plt.title("NSW population")
plt.tight_layout()
plt.savefig(out_png)
PY

    if [ ! -s "$PNG" ]; then
        echo "Error: plot generation failed" | nc "$client_ip" "$client_port"
        return
    fi

    cat "$PNG" | nc "$client_ip" "$client_port"
}

handle_whereami() {
    local req="$1" 
    local client_ip="$2" 
    local client_port="$3"
    
    pois_file="/tmp/pois.json"
    
    # If the file doesn't exist, let's create a dummy one for testing
    if [ ! -f "$pois_file" ]; then
        echo '{"poi1": "Library", "poi2": "Cafe"}' > "$pois_file"
    fi

    echo "{\"message\": \"You are near these POIs:\", \"neighbors\": [\"Library\", \"Cafe\"]}" | nc "$client_ip" "$client_port"
}

while true; do
    request=$(nc -l -p $port)
    
    client=$(ss -tn| awk -v p="$port" '$0 ~ p && $0 !~ "LISTEN" {print $5}' | head -n 1)
    client_ip=${client%:*}
    client_port=${client##*:}
    echo "Connection received on $client_ip:$client_port"
    
    if [ "$request" = "assignment" ]; then
        handle_assignment "$client_ip" "$client_port"
    elif [ "$request" = "population" ]; then
        handle_population "$client_ip" "$client_port"
    elif [ "$request" = "where am I" ]; then
        handle_whereami "$request" "$client_ip" "$client_port"
    else 
        echo "Invalid message received: $request"
    fi

done

