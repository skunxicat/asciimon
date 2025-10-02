#!/bin/bash

MONITOR=${1:-"autoscaling"}
TITLE="$(echo "$MONITOR" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"

if [ -n "$1" ];
then
    shift
fi

asciinema rec \
    --title "Realitime $TITLE Monitoring with **asciigraph**" \
    --command "utils/monitor.sh $MONITOR 2>/dev/null" \
    --overwrite "$MONITOR.cast" \
    "$@"

