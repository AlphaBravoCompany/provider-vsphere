<!--
Thanks for contributing to AlphaBravo provider-vsphere. CODEOWNERS assigns
reviewers from the maintainers listed in OWNERS.md.
-->

### Description of your changes

<!--
Briefly describe what this pull request does and anything reviewers should
look at closely. If it resolves an issue in this repository, keep the line
below and add the issue number, for example "Fixes #12". Otherwise delete it.
-->
Fixes #

I have:

- [ ] Run `make reviewable` (`make generate`, `make lint` and `make test`).
- [ ] Run `bash cluster/test/e2e-lab-selftest.sh` and `shellcheck -x cluster/test/e2e-lab.sh cluster/test/e2e-lab-selftest.sh` if this changes `cluster/test/` or the lab runbook (`RELEASING.md` sections 2 and 8).
- [ ] Committed everything `make generate` produced, so CI's `make check-diff` finds no diff. I did not hand-edit generated files (`zz_*`, `package/crds`, `examples-generated`).
- [ ] Updated `README.md` and `MIGRATION.md` if this changes the API (groups, kinds, fields or provider config), and explained any breaking change reported by CI's `make crddiff`.
- [ ] Run the lab e2e (`make e2e-lab`, which runs `cluster/test/e2e-lab.sh`) on a dedicated lab cluster, as described in `RELEASING.md` section 8, if this changes VirtualMachine behaviour, credentials handling or packaging. Otherwise I left this box unchecked.

### How has this code been tested

<!--
Describe the testing already done or planned, for example unit tests added
or a lab e2e run (Crossplane version and package tag).
-->
