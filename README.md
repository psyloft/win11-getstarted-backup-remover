# Win11 Get Started / Windows Backup Remover

移除 Windows 11 开始菜单的所有应用中的 **Get Started** 和 **Windows Backup** 入口。

这些入口在部分 Windows 11 版本中不是独立 Appx 包，而是注册在系统包 `MicrosoftWindows.Client.CBS` 中，所以普通 `Remove-AppxPackage` 通常无效。本项目提供备份、移除、缓存重置和恢复脚本。

## 风险

这不是 Microsoft 官方卸载方式。脚本可能修改：

```text
C:\Windows\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\AppxManifest.xml
C:\ProgramData\Microsoft\Windows\AppRepository\StateRepository-Machine.srd
```

可能影响 Windows 累计更新、开始菜单、搜索或 Appx 注册。请先备份，只在你能接受风险的设备上使用。

## 文件结构

```text
.
├── README.md
├── scripts/
│   ├── Backup-ClientCBS.ps1
│   ├── Remove-GetStartedWindowsBackup.ps1
│   ├── Reset-StartAppsCache.ps1
│   ├── Restore-ClientCBS.ps1
│   └── Verify-ClientCBS.ps1
├── src/
│   └── ClientCBS.Tools.psm1
├── .gitignore
└── .gitattributes
```

## 使用方法

以管理员身份打开 PowerShell，进入项目目录：

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
```

先检查当前状态：

```powershell
.\scripts\Verify-ClientCBS.ps1
```

创建备份：

```powershell
.\scripts\Backup-ClientCBS.ps1
```

移除 Get Started / Windows Backup：

```powershell
.\scripts\Remove-GetStartedWindowsBackup.ps1
```

如果脚本提示需要清理 `Get-StartApps` 残留，先尝试低风险缓存重置：

```powershell
.\scripts\Reset-StartAppsCache.ps1
shutdown /r /t 0
```

重启后仍然残留时，再执行 AppRepository 清理：

```powershell
.\scripts\Remove-GetStartedWindowsBackup.ps1 -SkipBackup -SkipManifest -CleanStartAppsResidue -InstallMySQLite
shutdown /r /t 0
```

`-InstallMySQLite` 会为当前用户安装 `MySQLite` PowerShell 模块，用于安全处理 AppRepository SQLite 数据库副本。

## 恢复

备份默认保存在：

```text
backups\ClientCBS-backup-yyyyMMdd-HHmmss\
```

恢复 Manifest：

```powershell
.\scripts\Restore-ClientCBS.ps1 -BackupPath .\backups\ClientCBS-backup-yyyyMMdd-HHmmss
shutdown /r /t 0
```

只有在 Windows Update、开始菜单、搜索或 Appx 注册异常时，才恢复 AppRepository 数据库：

```powershell
.\scripts\Restore-ClientCBS.ps1 -BackupPath .\backups\ClientCBS-backup-yyyyMMdd-HHmmss -RestoreStateRepository -InstallMySQLite
shutdown /r /t 0
```

如果系统已经安装过新的累计更新，不建议轻易恢复旧 `.srd` 数据库。

## 验证

运行：

```powershell
.\scripts\Verify-ClientCBS.ps1
```

成功时应看不到目标 Manifest 入口，也看不到目标 `Get-StartApps` 项：

```text
WebExperienceHost
WindowsBackup
Get Started
Windows Backup
```

## 免责声明

本项目用于个人研究和系统定制。使用者自行承担 Windows 更新失败、系统组件异常或修复成本等风险。
