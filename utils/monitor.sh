#!/bin/bash

# set -ex pipefail
# set -x 

ROOT_PATH="$(realpath "$(dirname "$0")/../..")"
AIRSWITCH_PATH="$ROOT_PATH/airswitch"

ECS_SERVICE=""
ECS_CLUSTER=""
SQS_QUEUE_URL=""


# shellcheck source=/dev/null
function setup () {
    read -r ECS_SERVICE ECS_CLUSTER SQS_QUEUE_URL <<< "$(cd "$AIRSWITCH_PATH" && \
        source ./activate 
        ecs_cluster=$(tf output  -raw  ecs_cluster) && \
        ecs_service=$(tf output -json ryanair | jq -r  '.ecs.booking.name')
        sqs_queue_url=$(tf output -json ryanair  | jq  -r  .sqs.default.endpoint)
        echo "$ecs_service $ecs_cluster $sqs_queue_url"
    )"
}

function sqs_attributes () {
    aws sqs get-queue-attributes \
            --queue-url "$SQS_QUEUE_URL" \
            --attribute-names All --output json \
            --query 'Attributes' \
            | jq '{ ApproximateNumberOfMessages, ApproximateNumberOfMessagesNotVisible}|map_values(tonumber)'
}

function ecs_tasks () {
    aws ecs describe-services \
        --cluster "$ECS_CLUSTER" \
        --services "$ECS_SERVICE" \
        --query 'services[0]' \
        --output json | jq '{desiredCount, runningCount, pendingCount}|map_values(tonumber)'
}

function fetch_data () {
    sqs_data="$(sqs_attributes)"
    ecs_tasks="$(ecs_tasks)"
    jq -n --argjson sqs "$sqs_data" --argjson ecs "$ecs_tasks" \
        '{sqs: $sqs, ecs: $ecs}'
}

function bootstrap () {
    echo "fetching infra outputs ..." >&2
    setup || exit 1
    echo "ready" >&2
}

# while true; do
#     fetch_data | jq -r '.sqs + .ecs|{ ApproximateNumberOfMessages, runningCount, ApproximateNumberOfMessagesNotVisible }|[.[]] | map(tonumber)  | join(",")'
#     sleep 0.4 
# done  | asciigraph -r \
#     -p 0 \
#     -w 80 \
#     -cc green \
#     -sn 3 \
#     -sl "Backlog,RunningTaskCount,Processing,PendingTaskCount" \
#     -sc "red,green,white" \
#     -lb 0 \
#     -ub 12 

monitor_autoascaling () {
    bootstrap
    while true; do
        fetch_data | jq -r '.sqs + .ecs |
        {   
            runningCount: (.runningCount|tonumber),
            idleTaskCount: (.runningCount|tonumber) - (.ApproximateNumberOfMessagesNotVisible|tonumber), 
            ApproximateNumberOfMessages: (.ApproximateNumberOfMessages|tonumber)
        }|[.[]]   | join(",")'
        sleep 0.4 
    done  \
    | asciigraph -r \
        -p 0 \
        -w 80 \
        -sn 3 \
        -sl "RunningTaskCount,IdleTaskCount,Backlog" \
        -sc "green,blue,red" \
        -lb 0 \
        -ub 12 
}

monitor_sqs () {
    bootstrap
    while true; do
        fetch_data | jq -r '.sqs + .ecs|{ ApproximateNumberOfMessages, ApproximateNumberOfMessagesNotVisible,  }|[.[]] | map(tonumber)  | join(",")'
        sleep 0.4 
    done  | asciigraph -r \
        -p 0 \
        -w 80 \
        -sn 2 \
        -sl "ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible" \
        -sc "red,blue" \
        -lb 0 \
        -ub 12 
}

monitor_ecs () {
    bootstrap
    # 
    while true; do
    fetch_data | jq -r '.sqs + .ecs|{ desiredCount, pendingCount, runningCount }|[.[]] | map(tonumber)  | join(",")'
    sleep 0.4 
done | asciigraph -r \
    -p 0 \
    -w 80 \
    -sn 3 \
    -sl "desiredCount,pendingCount,runningCount" \
    -sc "blue,white,green" \
    -lb 0 \
    -ub 12 
}

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
    *)
        echo "Usage: $0 [autoscaling|ecs]" >&2
        echo "  autoscaling - Monitor queue backlog and running tasks (default)" >&2
        echo "  ecs         - Monitor ECS service metrics" >&2
        echo "  sqs         - Monitor SQS queue activity" >&2
        exit 1
        ;;
esac
# desiredCount, runningCount, pendingCount

# fetch_data | jq -r '.sqs + .ecs|{ ApproximateNumberOfMessages, ApproximateNumberOfMessagesNotVisible, runningCount, pendingCount }|[.[]] | map(tonumber)  | join(",")'
# -sl "Queue Depth,Processing,Tasks Running,Tasks Pending" \
# -sn 4 \
# -ub 10 \