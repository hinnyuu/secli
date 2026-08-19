FROM nixos/nix:2.35.1@sha256:377d4887aca98f0dfa12971c1ea6d6a625a435d8b610d4c95a436843da6fbfd1

ARG SECLI_VERSION
ARG VCS_REF
ARG OCI_SOURCE=https://github.com/hinnyuu/secli

RUN printf '%s\n' 'experimental-features = nix-command flakes' >> /etc/nix/nix.conf \
  && nix profile add --profile /nix/var/nix/profiles/secli-base \
    github:NixOS/nixpkgs/ec2d622de0773551768cf98f3fc50cbcc003b9c5#git \
    github:NixOS/nixpkgs/ec2d622de0773551768cf98f3fc50cbcc003b9c5#ripgrep \
  && if [ -L /usr/share ]; then rm /usr/share; fi \
  && mkdir -p /usr/share/nvidia /usr/lib64 /usr/lib/nvidia /usr/local/nvidia

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0555 /entrypoint.sh

ENV SECLI_VERSION=${SECLI_VERSION} \
  PATH=/nix/var/nix/profiles/secli-base/bin:/nix/var/nix/profiles/default/bin

LABEL org.opencontainers.image.title="secli" \
  org.opencontainers.image.description="Secure Enhanced CLI runtime" \
  org.opencontainers.image.source="${OCI_SOURCE}" \
  org.opencontainers.image.revision="${VCS_REF}" \
  org.opencontainers.image.version="${SECLI_VERSION}"

ENTRYPOINT ["/entrypoint.sh"]
