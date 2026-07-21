import Foundation

enum AgentError: Error { case parse }

let failures = InterventionContractChecks.failures()
if !failures.isEmpty {
    fputs("PC18_CONTRACT_CHECKS: FAIL\n\(failures.joined(separator: "\n"))\n", stderr)
    exit(1)
}
print("PC18_CONTRACT_CHECKS: PASS")
