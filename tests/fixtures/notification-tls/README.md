# 通知测试证书

这里的证书和 RSA 密钥是公开的合成测试材料，用于隔离 VM 中的通知服务模拟器。证书有效期为 2020–2040 年，覆盖备份场景的时钟调整。

服务器与容器信任包引用同一份文件。固定内容使 Nix 缓存能够复用整条依赖链；更换证书时同时更换配对密钥，Nix 会重新构建依赖它们的服务器配置和容器信任包。

证书由 OpenSSL 自签，使用 SHA-256、序列号 1、`CA:TRUE`，SAN 为模拟器承接的四个通知域名。更新时保留这些约束，并用 `openssl verify -CAfile cert.pem -verify_hostname api.push.apple.com cert.pem` 检查信任关系。
