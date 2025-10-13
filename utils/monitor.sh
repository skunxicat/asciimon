#!/bin/bash

set -o pipefail
trap "exit 0" SIGPIPE SIGINT

#shellcheck source=/dev/null 
. "$(dirname "$0")/functions.sh"

# Parse command line arguments
case "${1:-autoscaling}" in
    "autoscaling")
        monitor_autoascaling
        ;;
    "ecs")
        monitor_ecs
        ;;
    "sqs")
        monitor_sqs
        ;;
    "consumers")
        monitor_consumers
        ;;
    "autoscaling_activities")
        autoscaling_activities
        ;;
    *)
        echo "Usage: $0 [autoscaling|ecs]" >&2
        echo "  autoscaling - Monitor queue backlog and running tasks (default)" >&2
        echo "  ecs         - Monitor ECS service metrics" >&2
        echo "  sqs         - Monitor SQS queue activity" >&2
        echo "  consumers   - Monitor consumers activity" >&2
        echo "  autoscaling_activities - Monitor autoscaling activities" >&2
        exit 1
        ;;
esac
