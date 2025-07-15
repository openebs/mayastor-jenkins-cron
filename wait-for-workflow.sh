#!/usr/bin/env bash

# Script from https://github.com/kamilchodola/wait-for-workflow-action with change for current_time checks

# ORG_NAME=openebs
# REPO_NAME=mayastor-control-plane
# REF=release/2.9
# MAX_FIND_MINUTES=3
# TIMEOUT_MINUTES=60
# INTERVAL_SECS=1
# WORKFLOW_ID="nightly-ci.yml"

set -u

# Set the maximum waiting time (in minutes) and initialize the counter
max_find_minutes="${MAX_FIND_MINUTES:-3}"
timeout="${TIMEOUT_MINUTES:-360}"
interval="${INTERVAL_SECS:-60}"
wait="${WAIT:-"true"}"
counter=0

# Get the current time in ISO 8601 format
current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
yesterday=$(date -u -d "yesterday" +"%Y-%m-%dT%H:%M:%SZ")
start_time=${START_TIME:-$yesterday}

# Check if REF has the prefix "refs/heads/" and append it if not
if [[ ! "$REF" =~ ^refs/heads/ ]]; then
  REF="refs/heads/$REF"
fi

HEADERS=(-H "Accept: application/vnd.github+json")
if [ -n "${GITHUB_TOKEN:-}" ]; then
  HEADERS+=(-H "Authorization: token $GITHUB_TOKEN")
fi

echo "ℹ️ Organization: ${ORG_NAME}"
echo "ℹ️ Repository: ${REPO_NAME}"
echo "ℹ️ Reference: $REF"
echo "ℹ️ Timeout to find the workflow: ${max_find_minutes} minutes"
echo "ℹ️ Timeout for the workflow to complete: ${timeout} minutes"
echo "ℹ️ Interval between checks: ${interval} seconds"

echo "ℹ️ Worflow Start Time: $start_time"
echo "ℹ️ Current Time: $current_time"

# If RUN_ID is not empty, use it directly
if [ -n "${RUN_ID:-}" ]; then
  run_id="${RUN_ID}"
  echo "ℹ️ Using provided Run ID: $run_id"
else
  workflow_id="${WORKFLOW_ID}" # Id of the target workflow
  echo "ℹ️ Workflow ID: $workflow_id"

  # Wait for the workflow to be triggered
  while true; do
    echo "⏳ Waiting for the workflow to be found..."
    response=$(curl -s "${HEADERS[@]}" \
      "https://api.github.com/repos/${ORG_NAME}/${REPO_NAME}/actions/workflows/${workflow_id}/runs")
    if echo "$response" | grep -q "API rate limit exceeded"; then
      echo "❌ API rate limit exceeded. Please try again later."
      exit 1
    elif echo "$response" | grep -q "Not Found"; then
      echo "❌ Invalid input provided (organization, repository, or workflow ID). Please check your inputs."
      exit 1
    fi
    run_id=$(echo "$response" | \
      jq -r --arg ref "$(echo "$REF" | sed 's/refs\/heads\///')" --arg current_time "$current_time" --arg start_time "$start_time" \
      '.workflow_runs[] | select(.head_branch == $ref and .created_at >= $start_time and .created_at <= $current_time) | .id')
    if [ -n "$run_id" ]; then
      WORKFLOW_SUB="$ORG_NAME/$REPO_NAME/actions/runs/$run_id"
      WORKFLOW_URL="https://github.com/$WORKFLOW_SUB"
      WORKFLOW_API_URL="https://api.github.com/repos/$WORKFLOW_SUB"
      if [ -n "${GITHUB_OUTPUT:-}" ]; then
        echo "workflow-url=$WORKFLOW_URL" >> "$GITHUB_OUTPUT"
        echo "workflow-api-url=$WORKFLOW_API_URL" >> "$GITHUB_OUTPUT"
        echo "workflow-id=$run_id" >> "$GITHUB_OUTPUT"
      fi
      echo "🎉 Workflow $run_id found at $WORKFLOW_URL"
      break
    fi

    # Increment the counter and check if the maximum waiting time is reached
    counter=$((counter + 1))
    if [ $((counter * $interval)) -ge $((max_find_minutes * 60)) ]; then
      echo "❌ Maximum waiting time for the workflow to be triggered has been reached. Exiting."
      exit 1
    fi

    sleep $interval
  done
fi

if [ "$wait" = "false" ] || [ "$wait" = "0" ]; then
  exit 0
fi

# Wait for the triggered workflow to complete and check its conclusion
timeout_counter=0
while true; do
  echo "⌛ Waiting for the workflow to complete..."
  run_data=$(curl -s "${HEADERS[@]}" \
    "https://api.github.com/repos/${ORG_NAME}/${REPO_NAME}/actions/runs/$run_id")
  status=$(echo "$run_data" | jq -r '.status')

  if [ "$status" = "completed" ]; then
    conclusion=$(echo "$run_data" | jq -r '.conclusion')
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      echo "workflow-conclusion=$conclusion" >> "$GITHUB_OUTPUT"
    fi
    if [ "$conclusion" != "success" ]; then
      echo "❌ The workflow has not completed successfully. Exiting."
      exit 1
    else
      echo "✅ The workflow completed successfully! Exiting."
      break
    fi
  fi

  # Increment the timeout counter and check if the timeout has been reached
  timeout_counter=$((timeout_counter + 1))
  if [ $((timeout_counter * interval)) -ge $((timeout * 60)) ]; then
    echo "❌ Timeout waiting for the workflow to complete. Exiting."
    exit 1
  fi

  sleep $interval
done
