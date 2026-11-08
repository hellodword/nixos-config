# 可选远端 VM 执行

本机无 KVM 时，可以用已准备的 vm-test-mcp 执行原生 `checks.x86_64-linux.vm-*`。常规构建和 GitHub Actions 不需要这个客户端。

```sh
nix develop .#vm --command vm-test-submit --version
nix develop .#vm --command vm-test-submit --help
```

使用执行器分配的 upload ID、传输 URL 和独立请求 ID 提交测试。客户端在本地求值并准备输入；记录最终任务 ID，完成后检查执行结果、证据和资源释放状态。详细协议与环境准备由[上游项目](https://github.com/hellodword/agents-misc/tree/master/tools/vm-test-mcp)负责。

当前客户端传输 derivation 和输入闭包，远端通过自己的 store 与缓存准备构建结果。本地已经构建 driver，不代表远端能直接复用这些产物；远端首次准备依赖的时间应与 VM 场景执行时间分别记录。

客户端来源由 `flake.lock` 的 `vm-test-tools` 固定；它不参与每日更新。需要升级时运行 `nix flake update vm-test-tools`，核对服务端与客户端的版本/构建身份，并用现有 VM 场景验证兼容性。

| 文件 | 兼容原因 | 移除条件 |
| --- | --- | --- |
| [client.nix](client.nix) | 锁定的上游只提供整包表达式；这里只安装 submit 客户端，但仍继承上游整包检查 | 上游提供独立客户端输出后直接引用 |
| [failure_artifacts.py](failure_artifacts.py) | 当前执行器只登记成功构建的输出根，失败时截图无法作为普通产物取回；用日志传输合成截图 | 上游能够收集失败截图后删除辅助函数及场景调用 |

测试中的 QMP、OCR、键盘输入、活动维持和关机使用[原生驱动封装](../../tests/vm/gui.py)，与这里的执行器兼容处理分开维护。
