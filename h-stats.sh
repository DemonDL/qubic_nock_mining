#!/usr/bin/env bash

# Get script directory for standalone testing
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Use HiveOS paths if available, otherwise use script directory
if [[ -z "$MINER_DIR" || -z "$CUSTOM_MINER" ]]; then
    MINER_PATH="$SCRIPT_DIR"
else
    MINER_PATH="$MINER_DIR/$CUSTOM_MINER"
fi

. "$MINER_PATH/h-manifest.conf"

# Parse stats from log file since miner has no API
LOG_FILE="${CUSTOM_LOG_BASENAME}.log"

if [[ ! -f "$LOG_FILE" ]]; then
    echo -e "${YELLOW}Log file not found: $LOG_FILE${NOCOLOR}"
    khs=0
    stats="null"
    exit 1
fi

# Get the last 50 lines for parsing (enough to capture one full stats block)
LOG_TAIL=$(tail -n 50 "$LOG_FILE" 2>/dev/null)

if [[ -z "$LOG_TAIL" ]]; then
    khs=0
    stats="null"
    exit 1
fi

# Parse the summary line: "521.14 Mh/s | Accepted: 3 - Rejected: 0 | Up: 19m 20s | jetskipool.ai"
summary_line=$(echo "$LOG_TAIL" | grep -E "^[0-9]+\.?[0-9]* Mh/s \|" | tail -1)

if [[ -z "$summary_line" ]]; then
    khs=0
    stats="null"
    exit 1
fi

# Extract total hashrate (Mhash/s)
total_hs=$(echo "$summary_line" | awk '{print $1}')

# Convert Mhash/s to khs (1 Mhash = 1000 kHash)
khs=$(echo "$total_hs" | awk '{print $1 * 1000}')

# Extract accepted/rejected
ac=$(echo "$summary_line" | grep -oP 'Accepted: \K[0-9]+')
rj=$(echo "$summary_line" | grep -oP 'Rejected: \K[0-9]+')
[[ -z "$ac" ]] && ac=0
[[ -z "$rj" ]] && rj=0

# Extract uptime and convert to seconds
#uptime_str=$(echo "$summary_line" | grep -oP 'Up: \K[0-9]+m [0-9]+s')
uptime_str=$(echo "$summary_line" | awk -F 'Up: |jetskipool.ai' '{print $2}' | sed 's/ *$//')
if [[ ! -z "$uptime_str" ]]; then
    up_h=$(echo "$uptime_str" | grep -oP '[0-9]+(?=h)')
    up_min=$(echo "$uptime_str" | grep -oP '[0-9]+(?=m)')
    up_sec=$(echo "$uptime_str" | grep -oP '[0-9]+(?=s)')
    uptime=$((up_h * 3600 + up_min * 60 + up_sec))
else
    uptime=0
fi

# Find line number of the last summary line
last_summary_line_num=$(echo "$LOG_TAIL" | grep -n -E "^[0-9]+\.?[0-9]* Mh/s \|" | tail -1 | cut -d: -f1)

# Get only lines after the last summary
if [[ ! -z "$last_summary_line_num" ]]; then
    gpu_lines=$(echo "$LOG_TAIL" | tail -n +$((last_summary_line_num + 1)) | grep -E "^\s+GPU\[#[0-9]+")
else
    gpu_lines=""
fi

# Count GPUs from the GPU lines after last summary
gpu_count=$(echo "$gpu_lines" | grep -c "GPU\[#" 2>/dev/null || echo "0")
[[ -z "$gpu_count" || "$gpu_count" == "0" ]] && gpu_count=0

declare -A gpu_hashrates

while IFS= read -r line; do
    if [[ -z "$line" ]]; then continue; fi
    # Extract GPU index
    gpu_idx=$(echo "$line" | grep -oP 'GPU\[#\K[0-9]+')
    # Extract hashrate
    gpu_hs=$(echo "$line" | grep -oP '[0-9]+\.?[0-9]*(?= Mh/s)')
    if [[ ! -z "$gpu_idx" && ! -z "$gpu_hs" ]]; then
        gpu_hashrates[$gpu_idx]=$gpu_hs
    fi
done <<< "$gpu_lines"

# Build hashrate array sorted by GPU index
hs_array="["
for ((i=0; i<gpu_count; i++)); do
    if [[ ! -z "${gpu_hashrates[$i]}" ]]; then
        # Convert Mhash/s to hash/s for the array (HiveOS expects raw values)
        hs_val=$(echo "${gpu_hashrates[$i]}" | awk '{printf "%.0f", $1 * 1000000}')
        hs_array+="$hs_val"
    else
        hs_array+="0"
    fi
    if [[ $i -lt $((gpu_count - 1)) ]]; then
        hs_array+=","
    fi
done
hs_array+="]"

# Get GPU temperatures from nvidia-smi
temps_array="["
fans_array="["
bus_array="["

if command -v nvidia-smi &> /dev/null; then
    gpu_temps=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null)
    gpu_fans=$(nvidia-smi --query-gpu=fan.speed --format=csv,noheader,nounits 2>/dev/null)
    gpu_bus=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null)

    i=0
    while IFS= read -r temp; do
        [[ $i -gt 0 ]] && temps_array+=","
        temps_array+="${temp:-null}"
        ((i++))
    done <<< "$gpu_temps"

    i=0
    na=N/A
    while IFS= read -r fan; do
        [[ $i -gt 0 ]] && fans_array+=","
        f="${fan:-null}"
        if [[ $f=$na ]]
        then
           fans_array+="0"
        else
           fans_array+="${fan:-null}"
        fi
        ((i++))
    done <<< "$gpu_fans"

    i=0
    while IFS= read -r bus; do
        [[ $i -gt 0 ]] && bus_array+=","
        # Extract bus number from format like "00000000:01:00.0"
        bus_num=$(echo "$bus" | grep -oP ':\K[0-9A-Fa-f]{2}(?=:)' | head -1)
        bus_dec=$((16#${bus_num:-0}))
        bus_array+="$bus_dec"
        ((i++))
    done <<< "$gpu_bus"
else
    # No nvidia-smi, fill with nulls
    for ((i=0; i<gpu_count; i++)); do
        [[ $i -gt 0 ]] && temps_array+=","
        [[ $i -gt 0 ]] && fans_array+=","
        [[ $i -gt 0 ]] && bus_array+=","
        temps_array+="null"
        fans_array+="null"
        bus_array+="null"
    done
fi

temps_array+="]"
fans_array+="]"
bus_array+="]"

# Build stats JSON for HiveOS
stats=$(jq -n \
    --argjson hs "$hs_array" \
    --arg hs_units "hs" \
    --arg algo "vecno" \
    --argjson temp "$temps_array" \
    --argjson fan "$fans_array" \
    --argjson uptime "$uptime" \
    --arg ac "$ac" \
    --arg rj "$rj" \
    --argjson bus_numbers "$bus_array" \
    --arg ver "vecnoski-miner" \
    '{hs: $hs, hs_units: $hs_units, algo: $algo, temp: $temp, fan: $fan, uptime: $uptime, ar: [$ac, $rj], bus_numbers: $bus_numbers, ver: $ver}')

[[ -z "$khs" ]] && khs=0
[[ -z "$stats" ]] && stats="null"
