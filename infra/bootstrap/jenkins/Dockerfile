# ==============================================================================
# Jenkins Controller personalizado con Docker CLI y herramientas CI
# Universidad Icesi - Ingesoft V
# ==============================================================================

FROM jenkins/jenkins:lts-jdk21

USER root

ARG KUBECTL_VERSION=v1.37.2
ARG KUSTOMIZE_VERSION=v5.7.1

# 1. Instalar dependencias y Docker CLI
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    git \
    openssh-client \
    procps \
    tar \
    gzip \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
       | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    case "$ARCH" in \
        amd64) \
            KUBECTL_SHA256=c04487523e7aa7d1493f7808174c899db93d7a9cf57531420cd76b9bd415f8f4; \
            KUSTOMIZE_SHA256=ea375e7372f9aa029129d4b2d16c66b7750b7f1213c4f66f910d981c895818d8; \
            ;; \
        arm64) \
            KUBECTL_SHA256=fcc16f63186659d9722014b7e02d5fdd2d4e669cb8c0ab66365d7d3b8ba03509; \
            KUSTOMIZE_SHA256=4261a040217df3bd6896597c3986d1465925726e4f22a945304b5233a4dcdbda; \
            ;; \
        *) echo "unsupported architecture: ${ARCH}" >&2; exit 1 ;; \
    esac; \
    TMP_DIR="$(mktemp -d)"; \
    trap 'rm -rf "${TMP_DIR}"' EXIT; \
    curl -fsSLo "${TMP_DIR}/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"; \
    echo "${KUBECTL_SHA256}  ${TMP_DIR}/kubectl" | sha256sum -c -; \
    install -m 0755 "${TMP_DIR}/kubectl" /usr/local/bin/kubectl; \
    curl -fsSLo "${TMP_DIR}/kustomize.tar.gz" "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz"; \
    echo "${KUSTOMIZE_SHA256}  ${TMP_DIR}/kustomize.tar.gz" | sha256sum -c -; \
    tar -xzf "${TMP_DIR}/kustomize.tar.gz" -C /usr/local/bin kustomize; \
    chmod 0755 /usr/local/bin/kustomize; \
    kubectl version --client=true; \
    kustomize version

# 2. Instalar plugins necesarios
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt

RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# 3. Ejecutar Jenkins con su usuario estándar
USER jenkins