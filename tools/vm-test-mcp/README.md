# 可选远端 VM 执行

本机无 KVM 时，可以用已准备的 vm-test-mcp 执行原生 `checks.x86_64-linux.vm-*`。`laptop` 开发环境提供提交客户端。

```sh
nix develop .#laptop --command vm-test-submit --version
nix develop .#laptop --command vm-test-submit --help
```

使用执行器分配的 upload ID、传输 URL 和独立请求 ID 提交测试。客户端在本地求值并准备输入；记录最终任务 ID，完成后检查执行结果、证据和资源释放状态。详细协议与环境准备由[上游项目](https://github.com/hellodword/agents-misc/tree/master/tools/vm-test-mcp)负责。

当前客户端传输 derivation 和输入闭包，远端通过自己的 store 与缓存准备构建结果。本地已经构建 driver，不代表远端能直接复用这些产物；远端首次准备依赖的时间应与 VM 场景执行时间分别记录。

客户端直接使用 `agents-misc` 暴露的 package，其版本和上游依赖由 `flake.lock` 固定。需要升级时运行 `nix flake update agents-misc`，核对服务端与客户端的版本/构建身份，并用现有 VM 场景验证兼容性。

测试中的 QMP、OCR、键盘输入、活动维持和关机使用[原生驱动封装](../../tests/vm/gui.py)。截图和诊断写入原生测试输出目录，由执行器收集；结果中分别检查断言、资源释放和证据收集状态。
