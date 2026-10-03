# Release lane (tech spec 12.3, ADR-0010). Releases publish only from the local
# release Mac; CI never signs or uploads. See docs/runbooks/testflight-release.md.

.PHONY: testflight op-check release-test

# Archive and upload to TestFlight: scripts/release.sh with the 1Password
# secrets from release/.env.example injected by scripts/op-run.sh. op-run.sh
# authenticates `op` with the service-account token in a git-ignored .env when
# there is one (non-interactive), else through the 1Password app (ADR-0016).
testflight:
	scripts/op-run.sh scripts/release.sh

# Only check that 1Password auth works and the OpenMoji vault is readable.
# Nothing else runs. Useful before a release, or to test a new .env.
op-check:
	scripts/op-run.sh --check

# Self-test of the lane scripts. Stubs every external tool: no signing, no
# network, no 1Password, no App Store Connect.
release-test:
	scripts/test-release.sh
