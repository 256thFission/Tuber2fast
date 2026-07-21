#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
output_dir="$repo_dir/tmp/pc18-contract-checks"
mkdir -p "$output_dir"

xcrun swiftc \
  "$repo_dir/TuberNotes/App/Contracts/SpatialContracts.swift" \
  "$repo_dir/TuberNotes/App/Contracts/PinContracts.swift" \
  "$repo_dir/TuberNotes/App/Contracts/InteractionContracts.swift" \
  "$repo_dir/TuberNotes/AgentHarness/InterventionOutcome.swift" \
  "$repo_dir/TuberNotes/AgentHarness/InterventionValidator.swift" \
  "$repo_dir/TuberNotes/AgentHarness/InterventionContractChecks.swift" \
  "$repo_dir/DeveloperTools/PC18ContractTests/main.swift" \
  -o "$output_dir/pc18-contract-checks"

"$output_dir/pc18-contract-checks"
