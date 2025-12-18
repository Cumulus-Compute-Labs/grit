#!/bin/bash
# CRIU action script - changes GPU mount propagation from slave → private at pre-dump phase
# This removes the master relationship that causes "unreachable sharing" errors

# Log everything for debugging
exec >> /tmp/criu-action.log 2>&1
echo "$(date): Action=$CRTOOLS_SCRIPT_ACTION PID=$CRTOOLS_INIT_PID"

if [ "$CRTOOLS_SCRIPT_ACTION" == "pre-dump" ]; then
    PID="$CRTOOLS_INIT_PID"
    
    if [ -z "$PID" ]; then
        echo "$(date): ERROR - CRTOOLS_INIT_PID is empty!"
        exit 0
    fi
    
    echo "$(date): Scanning /proc/$PID/mountinfo for NVIDIA GPU mounts with master relationships..."
    
    # Find GPU mounts that have master_id (slave mounts)
    # Field 5 is mount point, field 6 contains optional fields like "master:12"
    GPU_MOUNTS=$(awk '$5 ~ /^\/proc\/driver\/nvidia\/gpus\// {print $5}' "/proc/$PID/mountinfo" 2>/dev/null | sort -u)
    
    if [ -z "$GPU_MOUNTS" ]; then
        echo "$(date): No NVIDIA GPU mounts found"
    else
        echo "$(date): Found GPU mounts:"
        echo "$GPU_MOUNTS"
        
        # Change mount propagation from slave → private
        # This removes the master relationship without unmounting
        echo "$GPU_MOUNTS" | while read -r mnt_path; do
            echo "$(date): Changing propagation to private for: $mnt_path"
            
            # Use nsenter to enter container's mount namespace and change propagation
            nsenter -t "$PID" -m -- mount --make-private "$mnt_path" 2>&1 && {
                echo "$(date): SUCCESS - Changed $mnt_path to private"
            } || {
                echo "$(date): WARNING - Failed to change propagation for $mnt_path"
            }
        done
        
        # Verify - check if any mounts still have master relationship
        # In mountinfo, optional fields (field 6+) contain "master:N" for slave mounts
        echo "$(date): Verifying mount propagation..."
        cat "/proc/$PID/mountinfo" | grep "nvidia/gpus" | while read -r line; do
            echo "$(date): Mount info: $line"
        done
        
        # Check if master_id is still present (indicates still a slave)
        STILL_SLAVE=$(awk '$5 ~ /^\/proc\/driver\/nvidia\/gpus\// && /master:/ {print $5}' "/proc/$PID/mountinfo" 2>/dev/null | wc -l)
        if [ "$STILL_SLAVE" -eq 0 ]; then
            echo "$(date): SUCCESS - All GPU mounts are now private (no master relationship)"
        else
            echo "$(date): CRITICAL - $STILL_SLAVE mount(s) still have master relationship!"
        fi
    fi
fi

exit 0

