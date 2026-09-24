# No-fork runtime image: the vmware/vsphere provider plugin is compiled into the provider
# binary and runs in-process, so this image adds only that binary and the ca-certificates and
# bash packages (with bash's dependencies) to a current alpine base. Build time fetches the base
# image and, from the Alpine package repositories, those packages, so a build without network
# access fails. Nothing is downloaded at run time (Pioneer airgap mode).
FROM alpine:3.24.2
RUN apk --no-cache add ca-certificates bash

ARG TARGETOS
ARG TARGETARCH

ADD "bin/${TARGETOS}_${TARGETARCH}/provider" /usr/local/bin/provider

ENV USER_ID=65532

USER ${USER_ID}
EXPOSE 8080

ENTRYPOINT ["provider"]
