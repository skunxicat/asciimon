#!/bin/bash

set -o pipefail

ROOT_PATH="$(realpath "$(dirname "$0")/../..")"
AIRSWITCH_PATH="$ROOT_PATH/airswitch"

ECS_SERVICE=""
ECS_CLUSTER=""
ECS_CLUSTER_ARN=""
SQS_QUEUE_URL=""

REFRESH_INTERVAL=0.2
UB=12
W=84
# UB=18
# W=64

LAMBDA_REFRESH_INTERVAL=30


# shellcheck source=/dev/null
function setup () {
    read -r ECS_SERVICE ECS_CLUSTER ECS_CLUSTER_ARN SQS_QUEUE_URL <<< "$(cd "$AIRSWITCH_PATH" && \
        source ./activate 
        ecs_cluster=$(tf output  -raw  ecs_cluster) && \
        ecs_cluster_arn=$(tf output -json containers  | jq -r .ecs.cluster.arn) \
        ecs_service=$(tf output -json ryanair | jq -r  '.ecs.booking.name')
        sqs_queue_url=$(tf output -json ryanair  | jq  -r  .sqs.default.endpoint)
        echo "$ecs_service $ecs_cluster $ecs_cluster_arn $sqs_queue_url"
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

function ecs_tasks_protected () {
    aws ecs list-tasks \
    --cluster "$ECS_CLUSTER" \
    --service "$ECS_SERVICE" \
    --query taskArns \
    | jq   '.[]|split("/")|last' \
    | paste -s -d ' ' -  \
    | xargs -J {} \
    aws ecs get-task-protection \
    --cluster "$ECS_CLUSTER" \
    --query protectedTasks \
    --tasks {} | \
    jq 'map(select(.protectionEnabled))|length'
}

function fetch_data () {
    sqs_data="$(sqs_attributes)"
    ecs_tasks="$(ecs_tasks)"
    ecs_protected="$(ecs_tasks_protected)"
    jq -n --arg protected "$ecs_protected"  --argjson sqs "$sqs_data" --argjson ecs "$ecs_tasks" \
    ' (if $protected == "" then 0 else $protected end) as $protected|
        {sqs: $sqs, ecs: ($ecs + { protectedCount: $protected|tonumber })}
    '
}

function bootstrap () {
    echo "fetching infra outputs ..." >&2
    setup || exit 1
    echo "ready" >&2
}

function autoscaling_activities () {
    bootstrap
    local max_items=3
    local lines=$(( max_items +4 +1))
    while true; do
        aws application-autoscaling describe-scaling-activities \
            --service-namespace ecs \
            --resource-id "service/$ECS_CLUSTER_ARN/$ECS_SERVICE" \
            --query 'ScalingActivities[].[StartTime,Description,StatusCode]' \
            --output table \
            --max-items "$max_items"
        echo "UPDATED: $(date)"
        sleep 20
        # clean terminal lines
        # shellcheck disable=SC2034
        for i in $(seq 1 $lines); do
            tput cuu1
            tput el
        done
    done    
}

function lambda_concurrency () {
    local function_name
    function_name="$1"
    if [ -z "$function_name" ]; then
        echo "function name is required" >&2
        exit 1
    fi
    aws cloudwatch get-metric-statistics  \
        --namespace AWS/Lambda \
        --statistics Maximum \
        --metric-name ConcurrentExecutions \
        --dimensions Name=FunctionName,Value="${function_name}"  \
        --period 120  \
        --start-time "$(date -d '2 minutes ago')"  \
        --end-time "$(date )" \
        | jq -r  '.Datapoints|first.Maximum'
}

function monitor_autoascaling () {
    bootstrap
    while true; do
        fetch_data | jq -r '.sqs + .ecs |
        (.runningCount|tonumber) as $running |
        # (.ApproximateNumberOfMessagesNotVisible|tonumber) as $processing | 
        (.desiredCount|tonumber) as $desired |
        # (if $running > $processing then $running - $processing else 0 end) as $idle |
        (if $running > .protectedCount then $running - .protectedCount else 0 end) as $idle |
        ($running - $idle) as $working | 
        (.ApproximateNumberOfMessages|tonumber) as $messages | 
        {   
            desiredCount: $desired,
            runningCount: $running,
            # idleTaskCount: $idle, 
            ApproximateNumberOfMessages: $messages,
            # protectedCount: .protectedCount,
            workingCount: $working,
        }|[.[]]   | join(",")'
        sleep "$REFRESH_INTERVAL"
    done   \
    | asciigraph -r \
        -p 0 \
        -w "$W" \
        -sn 4 \
        -sl "DesiredTaskCount,RunningTaskCount,Backlog,WorkingTaskCount" \
        -sc "blue,green,white,red" \
        -lb 0 \
        -ub "$UB"
}

function monitor_consumers () {
    bootstrap
    while true; do
        fetch_data | jq -r '.sqs + .ecs |
        (.runningCount|tonumber) as $running |
        # (.ApproximateNumberOfMessagesNotVisible|tonumber) as $processing | 
        (.desiredCount|tonumber) as $desired |
        # (if $running > $processing then $running - $processing else 0 end) as $idle |
        (if $running > .protectedCount then $running - .protectedCount else 0 end) as $idle |
        ($running - $idle) as $working | 
        (.ApproximateNumberOfMessages|tonumber) as $messages | 
        {   
            desiredCount: $desired,
            # ApproximateNumberOfMessages: $messages,
            runningCount: $running,
            idleTaskCount: $idle, 
            # ApproximateNumberOfMessages: $messages,
            # protectedCount: .protectedCount,
            workingCount: $working,
        }|[.[]]   | join(",")'
        sleep "$REFRESH_INTERVAL"
    done   \
    | asciigraph -r \
        -p 0 \
        -w 84 \
        -sn 4 \
        -sl "DesiredTaskCount,RunningTaskCount,IdleTaskCount,WorkingTaskCount" \
        -sc "blue,green,white,red" \
        -lb 0 \
        -ub "$UB"
}

function monitor_sqs () {
    bootstrap
    while true; do
        timestamp=$(date +%H:%M:%S)
        data=$(fetch_data | jq -r '.sqs + .ecs|{ ApproximateNumberOfMessages, ApproximateNumberOfMessagesNotVisible,  }|[.[]] | map(tonumber)  | join(",")')
        echo "$data"
        echo "$timestamp" >&2
        sleep "$REFRESH_INTERVAL"
    done  | asciigraph -r \
        -p 0 \
        -w 84 \
        -sn 2 \
        -sl "ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible" \
        -sc "green,red" \
        -lb 0 \
        -ub "$UB"
}

function monitor_ecs () {
    bootstrap
    # 
    while true; do
    fetch_data | jq -r '.sqs + .ecs|{ desiredCount, pendingCount, runningCount, protectedCount }|[.[]] | map(tonumber)  | join(",")'
    sleep "$REFRESH_INTERVAL"
done | asciigraph -r \
    -p 0 \
    -w 84 \
    -sn 4 \
    -sl "desiredCount,pendingCount,runningCount,protectedCount" \
    -sc "blue,white,green,red" \
    -lb 0 \
    -ub "$UB"
}

function monitor_lambda_concurrency () {
    local function_name
    local refresh_interval
    function_name="$1"
    refresh_interval="${2:-$LAMBDA_REFRESH_INTERVAL}"
    if [ -z "$function_name" ]; then
        echo "function name is required" >&2
        exit 1
    fi
    while true; do
        lambda_concurrency "$function_name" | \
        asciigraph -r \
            -p 0 \
            -w 84 \
            -sn 1 \
            -sl "Concurrency" \
            -sc "green" \
            -lb 0 \
            -ub 12
        sleep "$refresh_interval"
    done
}