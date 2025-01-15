# Provider vSphere

This is a fork of the [Ankasoft vSphere provider](https://github.com/ankasoftco/provider-vsphere) Utilizing a higher version of the [Terraform vSphere provider](https://github.com/hashicorp/terraform-provider-vsphere) In order to capture bugfixes related to deploying OVF/OVA files directly to an ESXi host.

`provider-vsphere` is a [Crossplane](https://crossplane.io/) provider that
is built using [Upjet](https://github.com/upbound/upjet) code
generation tools and exposes XRM-conformant managed resources for the
vSphere API.

Alternatively, you can use declarative installation:
```
cat <<EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-vsphere
spec:
  package:docker.io/andrewkumlin/provider-vsphere-amd64:latest
EOF
```

Notice that in this example Provider resource is referencing ControllerConfig with debug enabled.


## Developing

Run code-generation pipeline:
```console
go run cmd/generator/main.go "$PWD"
```

Run against a Kubernetes cluster:

```console
make run
```

Build, push, and install:

```console
make all
```

Build binary:

```console
make build
```

## Report a Bug

For filing bugs, suggesting improvements, or requesting new features, please
open an [issue](https://github.com/Kumlin/provider-vsphere/issues).
