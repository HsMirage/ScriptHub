# ScriptHub

ScriptHub 用来收集和维护各类服务器脚本，目标是把常用部署、管理、备份、排障操作整理成可直接运行的脚本。

## AI 工具安装管理脚本

当前主要脚本是 `AI/ai-tools-manager.sh`，用于统一管理一组 AI 相关服务，例如 NewAPI、AxonHub、CLIProxyAPI、9Router、PostgreSQL 和 Cockpit Tools。

一键运行：

```bash
bash <(curl -s -L https://raw.githubusercontent.com/HsMirage/ScriptHub/main/AI/ai-tools-manager.sh)
```

如果服务器没有 `curl`，可以先安装 `curl` 后再执行。

## 注意事项

- 建议使用 `root` 权限运行。
- 生产环境操作更新、重启、卸载前，请先确认已有数据库备份。
- AxonHub 请求明细可能非常大，不建议在磁盘空间不足时做完整数据库备份。
- 脚本会优先使用 Docker Compose 管理服务，需要服务器已安装 Docker 和 Docker Compose。

## 文件说明

- `AI/ai-tools-manager.sh`：AI 工具安装管理脚本，方便通过 GitHub Raw URL 直接运行。

## 许可

MIT License
