# g-stack shell helpers — paste into your ~/.zshrc (or .bashrc).
#
# Prereq: gcloud installed and authenticated; you've been added to the
# `vulture-vision-cloud` GCP project with at least `roles/compute.osLogin`.
#
# Usage:
#   claw  collector "<question>"   # factual, warehouse-anchored answer
#   claw  coach     "<question>"   # interpretive, Telegram-style answer
#   clawj coach     "<question>"   # same but --json (machine-parseable)

unalias claw  2>/dev/null
unalias clawj 2>/dev/null

claw() {
  local agent="$1"; shift
  local msg="$*"
  gcloud compute ssh hackathon-openclaw --zone us-central1-a \
    --command="set -a; source ~/.env; set +a; openclaw agent --agent $agent --local --message $(printf '%q' "$msg")"
}

clawj() {
  local agent="$1"; shift
  local msg="$*"
  gcloud compute ssh hackathon-openclaw --zone us-central1-a \
    --command="set -a; source ~/.env; set +a; openclaw agent --agent $agent --local --json --message $(printf '%q' "$msg")"
}
