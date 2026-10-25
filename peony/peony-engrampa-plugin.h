/* -*- Mode: C++; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- */
/*
 * Engrampa 的 peony-qt(UKUI 文件管理器)右键菜单插件
 *
 * 提供两个一步到位压缩项:
 *   压缩为 <模板展开名>  —— BandiZip 式命名模板,不弹对话框
 *   压缩为加密压缩文件    —— WinRAR 式预设密码,不弹对话框
 * 实际压缩逻辑由 engrampa --instant-add [--encrypt] 完成
 * (见 engrampa 主程序 src/dlg-batch-add.c)。
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#ifndef PEONY_ENGRAMPA_PLUGIN_H
#define PEONY_ENGRAMPA_PLUGIN_H

#include <QObject>
#include <QAction>
#include <QIcon>
#include <QList>
#include <QString>
#include <QStringList>

#include "peony-qt/plugin-iface.h"
#include "peony-qt/menu-plugin-iface.h"

class PeonyEngrampaPlugin : public QObject, public Peony::MenuPluginInterface
{
    Q_OBJECT
    Q_INTERFACES(Peony::MenuPluginInterface)
    Q_PLUGIN_METADATA(IID "org.ukui.peony-qt.plugin-iface.MenuPluginInterface")

public:
    explicit PeonyEngrampaPlugin(QObject *parent = nullptr);

    Peony::PluginInterface::PluginType pluginType() override {
        return Peony::PluginInterface::MenuPlugin;
    }
    const QString name() override { return QStringLiteral("Engrampa Compress Plugin"); }
    const QString description() override {
        return QStringLiteral("One-click compress actions powered by engrampa");
    }
    const QIcon icon() override { return QIcon::fromTheme(QStringLiteral("engrampa")); }
    void setEnable(bool enable) override { m_enabled = enable; }
    bool isEnable() override { return m_enabled; }

    QString testPlugin() override { return QStringLiteral("ok"); }

    QList<QAction *> menuActions(Peony::MenuPluginInterface::Types types,
                                 const QString &uri,
                                 const QStringList &selectionUris) override;

private:
    bool m_enabled = true;
};

#endif /* PEONY_ENGRAMPA_PLUGIN_H */
