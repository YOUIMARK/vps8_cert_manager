# vps8 CertCenter 证书管理脚本

自动管理 [vps8 CertCenter](https://vps8.zz.cd/certcenter) 证书的交互式 Bash 脚本。

## 功能

- 交互式菜单，首次运行输入 API Key 后自动保存
- 查询证书到期时间
- 下载证书到 `/cert/<域名>/`
- 手动发起续签
- 一键设置定时自动续签（每天北京时间 01:00）
- 管理已保存的域名及定时任务
- 一键卸载（保留 `/cert` 目录）

## 快速开始

只需下载一个文件：

```bash
curl -O https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/cert_manager.sh
chmod +x cert_manager.sh
bash cert_manager.sh
```

首次运行会自动：
1. 创建 `~/vps8_cert_manager/` 目录
2. 将脚本复制到该目录并删除原文件
3. 生成 `cert_cron.sh`（供定时任务调用）
4. 提示输入 API Key（在 [个人资料页](https://vps8.zz.cd/client/profile) 获取）

之后运行：

```bash
bash ~/vps8_cert_manager/cert_manager.sh
```

## 目录结构

```
~/vps8_cert_manager/
├── cert_manager.sh    # 主脚本（自动安装）
├── cert_cron.sh       # 自动生成，供 crontab 调用
├── config.conf        # API Key 及域名列表（权限 600）
└── logs/
    └── cert_manager.log
```

证书存放位置：

```
/cert/
└── example.com/
    ├── fullchain.pem  (644)
    ├── cert.pem       (644)
    └── privkey.pem    (600)
```

## 依赖

- `bash` ≥ 4.0
- `curl`
- `grep`（需支持 `-P`，Linux 默认满足；macOS 需安装 GNU grep）

## 卸载

在菜单中选择「5. 卸载脚本」，将删除 `~/vps8_cert_manager` 目录及所有相关 crontab 条目。

证书文件不会被删除。如需手动删除：

```bash
rm -rf /cert
```

## License

MIT
