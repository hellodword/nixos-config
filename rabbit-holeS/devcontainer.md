# devcontainer

## ssh

- `~/.ssh/config` 是链接，不过实测容器直接挂 `~/.ssh/config` 会挂进真实路径的文件，但是挂 `~/.ssh` 则会挂进链接
- 但是直接把 `~/.ssh/config` mount 到 `~/.ssh/config` 会导致 `~/.ssh` 的权限有问题，所以 mount 到其它路径再通过 `onCreateCommand` 处理到 `~/.ssh/config`
- VSCode 会自动转发和设置 `$SSH_AUTH_SOCK`

```json
{
  "image": "ghcr.io/hellodword/devcontainers-images-pyinfra",
  "mounts": [
    {
      "source": "/home/ubuntu/.ssh/config",
      "target": "/etc/ssh/from_host/config",
      "type": "bind"
    },
    {
      "source": "/home/ubuntu/.ssh/known_hosts",
      "target": "/etc/ssh/from_host/known_hosts",
      "type": "bind"
    },
    {
      "source": "/etc/ssh/gpg.github.<...>.pub",
      "target": "/etc/ssh/gpg.github.<...>.pub",
      "type": "bind"
    },
    {
      "source": "/etc/ssh/gpg.gitlab.<...>.pub",
      "target": "/etc/ssh/gpg.gitlab.<...>.pub",
      "type": "bind"
    },
    {
      "source": "/etc/ssh/gpg.<...>.<...>.pub",
      "target": "/etc/ssh/gpg.<...>.<...>.pub",
      "type": "bind"
    },
    {
      "source": "/etc/ssh/gpg.vps.<...>.pub",
      "target": "/etc/ssh/gpg.vps.<...>.pub",
      "type": "bind"
    }
  ],
  "onCreateCommand": "mkdir -p $HOME/.ssh; cat /etc/ssh/from_host/config > $HOME/.ssh/config && cat /etc/ssh/from_host/known_hosts > $HOME/.ssh/known_hosts && sed -i 's@127.0.0.1@172.17.0.1@g' $HOME/.ssh/config"
}
```
