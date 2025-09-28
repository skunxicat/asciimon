#!/bin/bash

asciinema rec \
    --title "Realitime Autoscaling Monitoring with **asciigraph**" \
    --command "utils/monitor.sh autoscaling" \
    --capture-input \
    --overwrite autoscaling.cast 


