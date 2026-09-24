# Forge Context: vSphere Provider Upgrade + Crossplane v2 Support

## Goal

1. Upgrade the Terraform vSphere provider from `2.12.0` to **`2.15.1`**, the newest release that
   still supports vSphere 7.
2. Migrate the generator from **upjet 0.9 to upjet v2** so the provider is a native Crossplane v2
   provider.
3. Generate **both** cluster-scoped and namespaced (Crossplane v2) managed resources, in a single
   change.

**Why now:** stay on the latest provider that still meets our vSphere requirements. Our product,
Pioneer, already runs Crossplane v2, but this provider was built with the Crossplane v1 toolchain.

## Hard Constraints

- **vSphere / vCenter:** must support **7.0 U3** and **8.0 U2**.
- **Crossplane:** v2 (what Pioneer deploys today).
- **Kubernetes:** k3s (Pioneer's distro).
- **Open-source Terraform only:** do not depend on any Terraform release under the BUSL license
  (1.6+). The build must use either Terraform ≤ 1.5.x (MPL-2.0) or OpenTofu.
- **Registry:** Docker Hub, `alphabravodevops/provider-vsphere`.
- **Architectures:** publish multi-arch packages (`linux_amd64`, `linux_arm64`; the current
  `PLATFORMS` value in the Makefile).

## Freedom to Break Things

- There are **no managed resources in any live cluster** and no known external users of this fork.
- **We may change API groups, CRD names, and kinds** to match Crossplane/upjet v2 conventions.
- Pioneer will be updated to use the new CRDs.

## Resources in Scope

- **All resources** in the Terraform provider must be generated and must compile.
- **Priority:** `virtual_machine` (`virtualmachine` group). It is the only resource Pioneer
  deploys today, so it must be proven end-to-end.

## Verified Facts (checked 2026-09-23)

**Upstream provider moved.** HashiCorp transferred the provider to VMware:

| | Old (current Makefile) | New |
|---|---|---|
| Registry source | `hashicorp/vsphere` (last version: 2.12.0) | `vmware/vsphere` |
| Repo | `github.com/hashicorp/terraform-provider-vsphere` | `github.com/vmware/terraform-provider-vsphere` |
| Downloads | `releases.hashicorp.com/...` | needs to be confirmed for the new source |

All `TERRAFORM_PROVIDER_*` Makefile variables and the provider config source must be updated.

**Why 2.15.1:**
- v2.15.2 (2026-03-26) is a documentation-only release: it drops vSphere 7.x from the supported
  list and adds 9.x.
- v2.16.0+ (the latest is v2.17.1) are officially vSphere 8+/9 only.
- v2.15.1 is on both the Terraform and OpenTofu registries.

**Current repo state:**
- upjet: `github.com/upbound/upjet v0.9.0-rc` (Apr 2023)
- crossplane-runtime: v0.20.0-rc
- Go: 1.18
- Terraform CLI: 1.5.5
- `build` submodule: `github.com/upbound/build`
- API groups: `*.crossplane.io`, e.g. `virtualmachine.crossplane.io`, `storage.crossplane.io`, and
  `vsphere.crossplane.io` (10 groups)
- Existing Docker Hub tags: `latest`, `2.12.0-terraform-vsphere`,
  `2.12.0-terraform-vsphere-1.19-go`, `2.12.0-terraform-vsphere-1.21-go`

## Open Questions for the Interview

- **API group naming:** keep `*.crossplane.io`, or move to a group we own
  (e.g. `*.vsphere.alphabravo.io`)? What should the cluster-scoped vs. namespaced group pattern be
  under upjet v2 conventions (e.g. `<group>.vsphere.<domain>` and `<group>.vsphere.m.<domain>`)?
- **Terraform CLI:** pin Terraform 1.5.x (MPL), or switch the build to OpenTofu?
- **Provider execution:** use upjet's no-fork mode (the Terraform provider runs in-process, the
  recommended default for upjet v2) or keep the CLI-based mode?
- **Build tooling:** switch the `build` submodule to `github.com/crossplane/build`, or keep it?
- **Tag scheme:** what Docker Hub tags should the release get (e.g. `v2.15.1`, `latest`)?
- **"Both in one MR":** does "MR" mean one merge request, or both managed-resource scopes?
  (Either way the outcome is the same: cluster-scoped and namespaced together.)

## Build, Release, and Test

**Build:**
- `make generate` regenerates the code.
- `make build` produces the `.xpkg` in `_output/`.
- `make run` runs the provider locally, outside Kubernetes, as a smoke check.

**Release:**
- Push with `up xpkg push` or `crossplane xpkg push`:
  `<repo>:<tag> -f <file.xpkg>`
- Do **not** use `docker push`. It strips the xpkg annotation layer
  (crossplane/crossplane#5579, #5785).
- Multi-arch: push one xpkg per platform, or a combined index. The approach needs to be confirmed.
- Docker Hub credentials are supplied interactively at release time and never committed.

**Test:**
1. Install Crossplane v2 and the provider on a k3s instance.
2. Deploy a basic VM against a real lab vCenter.
3. Cover both a cluster-scoped and a namespaced `VirtualMachine`.

## Out of Scope

- Changes to Pioneer itself (it will be updated separately to the new CRDs).
- Publishing to the Upbound Marketplace.

## Background: Previous Manual Process (from a colleague's notes)

- **Lineage:** this repo forks `Kumlin/provider-vsphere`, which forks `kirillinda/provider-vsphere`,
  which forks `ankasoftco/provider-vsphere`. The fork was chosen because upstream community
  providers lagged the Terraform provider and were missing OVF/OVA-to-ESXi deployment fixes.
- **Past upgrades:**
  1. Bump `TERRAFORM_PROVIDER_VERSION` and `TERRAFORM_NATIVE_PROVIDER_BINARY` in the Makefile.
  2. Adjust configs under `config/` for new or changed resources.
  3. Run `make generate`, then `make run`, then `make build`.
  4. Push with `up xpkg push`.
- **Example install manifest:**

  ```yaml
  apiVersion: pkg.crossplane.io/v1
  kind: Provider
  metadata:
    name: provider-vsphere
  spec:
    package: docker.io/alphabravodevops/provider-vsphere:<tag>
  ```

  Crossplane v2 requires fully qualified package paths like this one.
- **Harbor** was mentioned as an option for private registry hosting. It is not used today.
