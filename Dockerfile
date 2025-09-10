# -------------------------------------------------------------------
# Stage 1: Build docker-credential-ecr-login
# -------------------------------------------------------------------
FROM golang:1.9-alpine3.6 AS ecr-helper-builder
RUN apk add --no-cache git
WORKDIR /go/src/github.com/awslabs/amazon-ecr-credential-helper
RUN git clone https://github.com/awslabs/amazon-ecr-credential-helper.git . \
    && git checkout 68cfee07af64
RUN env CGO_ENABLED=0 go build -a -installsuffix "static" \
    -o /go/bin/docker-credential-ecr-login \
    ./ecr-login/cli/docker-credential-ecr-login

# -------------------------------------------------------------------
# Stage 2: Build aws-iam-authenticator + Docker binary
# -------------------------------------------------------------------
FROM golang:1.25.0 AS gobuilder

WORKDIR /src
RUN git clone https://github.com/kubernetes-sigs/aws-iam-authenticator.git . \
    && go mod tidy \
    && go get github.com/go-viper/mapstructure/v2@v2.4.0 \
    && go build -ldflags="-s -w" -o /aws-iam-authenticator ./cmd/aws-iam-authenticator
RUN set -ex \
    && echo "Installing Docker version 28.4.0" \
    && mkdir -p /usr/test/ \
    && curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-28.4.0.tgz" \
       | tar -xz --strip-components=1 -C /usr/test/


# -------------------------------------------------------------------
# Stage 3: Base image (Jenkins agent + Java setup)
# -------------------------------------------------------------------
FROM 702020459620.dkr.ecr.us-east-1.amazonaws.com/odavid-jenkins-jnlp-slave:3107.v665000b_51092-15-jdk17 AS base

USER root
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-dev libpq-dev \
      jq curl git wget ca-certificates openssh-client gettext-base \
    && rm -rf /var/lib/apt/lists/*

RUN rm -rf /opt/java/openjdk \
    && mkdir -p /opt/java \
    && wget -qO- https://corretto.aws/downloads/latest/amazon-corretto-21-x64-linux-jdk.tar.gz \
       | tar -xz -C /opt/java \
    && mv /opt/java/amazon-corretto-* /opt/java/openjdk

ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="$JAVA_HOME/bin:$PATH"

RUN rm -f /usr/bin/docker /usr/bin/containerd-shim \
          /usr/bin/runc

RUN pip install --upgrade awscli==1.42.13
RUN pip install --upgrade s3cmd==2.4.0 #awsebcli==3.18.1
RUN pip install --upgrade \
    PyYAML==5.4 \
    cryptography==44.0.1 \
    requests==2.32.4 \
    rsa==4.7 \
    urllib3==2.5.0


# -------------------------------------------------------------------
# Stage 4: Final image
# -------------------------------------------------------------------
FROM base

RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash \
    && mv /usr/local/bin/helm /usr/bin/helm

RUN curl -sSL "https://dl.k8s.io/release/$(curl -s https://cdn.dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    -o /usr/bin/kubectl \
    && chmod +x /usr/bin/kubectl

COPY --from=ecr-helper-builder /go/bin/docker-credential-ecr-login /usr/bin/
COPY --from=gobuilder /aws-iam-authenticator /usr/bin/
COPY --from=gobuilder /usr/test/* /usr/bin/

COPY agent.jar /usr/share/jenkins/agent.jar
