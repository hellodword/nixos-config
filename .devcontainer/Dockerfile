# https://github.com/coder/coder/blob/ef2411ef1709ca2e9577bc6294c2edbd9b3a0ec1/.devcontainer/Dockerfile

# [Choice] Ubuntu version (use jammy or bionic on local arm64/Apple Silicon): jammy, focal, bionic
ARG VARIANT="jammy"
FROM buildpack-deps:${VARIANT}-curl

LABEL dev.containers.features="common"

RUN apt-get update

RUN env DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
	ca-certificates \
	bash-completion \
	build-essential \
	curl \
	cmake \
	direnv \
	emacs-nox \
	gnupg \
	htop \
	jq \
	less \
	lsb-release \
	lsof \
	man-db \
	nano \
	vim \
	ssl-cert \
	sudo \
	unzip \
	xz-utils \
	zip \
	git \
	openssh-client \
	netcat

ENV EDITOR=vim

# configure locales to UTF8
RUN apt-get install locales && locale-gen en_US.UTF-8
ENV LANG='en_US.UTF-8' LANGUAGE='en_US:en' LC_ALL='en_US.UTF-8'

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# https://github.com/zimbatm/vscode-devcontainer-nix/blob/e1777e7072d8b89b18fbcd0c20b2030291f64257/Dockerfile
# This Dockerfile adds a non-root user with sudo access. Use the "remoteUser"
# property in devcontainer.json to use it. On Linux, the container user's GID/UIDs
# will be updated to match your local UID/GID (when using the dockerFile property).
# See https://aka.ms/vscode-remote/containers/non-root-user for details.
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID
ENV HOME=/home/$USERNAME

RUN groupadd --gid $USER_GID $USERNAME \
  && useradd -s /bin/bash --uid $USER_UID --gid $USER_GID -m $USERNAME

RUN echo "$USERNAME ALL=(ALL) NOPASSWD:ALL">/etc/sudoers.d/90-cloud-init-users

RUN mkdir -p $HOME && \
	chown -R $USER_UID:$USER_GID $HOME

RUN mkdir -m 0755 /nix && chown "$USERNAME" /nix

USER $USERNAME

# install nix
RUN sh <(curl -L https://nixos.org/nix/install) --no-daemon
ENV PATH="$PATH:$HOME/.nix-profile/bin"

RUN mkdir -p $HOME/.config/nix $HOME/.config/nixpkgs \
	&& echo 'sandbox = false' >> $HOME/.config/nix/nix.conf \
	&& echo '{ allowUnfree = true; }' >> $HOME/.config/nixpkgs/config.nix \
	&& echo '. $HOME/.nix-profile/etc/profile.d/nix.sh' >> $HOME/.bashrc

# # install docker and configure daemon to use vfs as GitHub codespaces requires vfs
# # https://github.com/moby/moby/issues/13742#issuecomment-725197223
# RUN mkdir -p /etc/apt/keyrings \
# 	&& curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
# 	&& echo \
# 	"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
# 	$(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null \
# 	&& apt-get update \
# 	&& apt-get install --yes docker-ce docker-ce-cli containerd.io docker-compose-plugin \
# 	&& mkdir -p /etc/docker \
# 	&& echo '{"cgroup-parent":"/actions_job","storage-driver":"vfs"}' >> /etc/docker/daemon.json

ENV NIX_CONFIG="extra-experimental-features = nix-command flakes repl-flake"

ADD shell.nix $HOME/
ADD flake.lock $HOME/
# Clean up non-essential downloaded archives after provisioning a shell.
RUN cd $HOME && nix-shell $HOME/shell.nix --command true

# RUN nix-channel --update

# configure direnv
RUN direnv hook bash >> "$HOME/.bashrc"
RUN cd $HOME && echo "export PATH=$PATH:$(nix-shell $HOME/shell.nix --command 'echo $PATH')" >> "$HOME/.bashrc"


# # install nixd
# RUN git clone --depth=1 https://github.com/nix-community/nixd /tmp/nixd && \
# 	cd /tmp/nixd && \
# 	nix build -L .#
# RUN	cd /tmp/nixd && \
# 	echo "export PATH=\$PATH:$(nix build --print-out-paths -L .#)/bin" >> "$HOME/.bashrc"

# add code to PATH
RUN echo 'export PATH="$PATH:$(dirname $BROWSER)/../../bin/remote-cli"' >> "$HOME/.bashrc"

RUN echo 'source $HOME/.nix-profile/share/bash-completion/completions/nix' >> "$HOME/.bashrc"

RUN mkdir -p "$HOME/.config/sops/age/"
